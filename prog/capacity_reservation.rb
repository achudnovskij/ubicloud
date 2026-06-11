# frozen_string_literal: true

# Prog::CapacityReservation holds standing extra AWS On-Demand Capacity
# Reservations (ODCRs) in a single Location so Postgres workloads can scale up /
# failover without AWS returning InsufficientInstanceCapacity. One Strand per
# Location; all state lives in the strand stack frame (no model/table).
class Prog::CapacityReservation < Prog::Base
  semaphore :pause, :rebalance, :destroy

  frame_accessor :current_target, :last_observed_usage, :current_usage_per_az,
    :reconcile_pending, :last_measured_at, :azs_insufficient

  VALID_CONSTRAINT_KEYS = %w[minimum_cpu minimum_storage sizes minimum_provisioned_cpu minimum_provisioned_storage].freeze
  # The "provisioned" variants resolve to the same catalog/threshold size set as
  # their bare counterparts, but eligible_instance_types then intersects them with
  # current usage — so they cover only sizes actually in use, never pre-warm.
  PROVISIONED_CONSTRAINT_KEYS = %w[minimum_provisioned_cpu minimum_provisioned_storage].freeze
  EDITABLE_KEYS = %w[instance_families enable_all_families additional_capacity allowed_capacity_decrease reconcile_interval remove_orphaned_reservations min_available_az_insufficient_action].freeze

  # What to do when AWS offers a type (or the whole location) in fewer than the
  # required 3 AZs: PAGE raises an incident, WARN just logs. Defaults to PAGE;
  # set WARN per-location for regions where a needed family (e.g. Graviton4 8gd)
  # is genuinely offered in < 3 AZs and would otherwise page indefinitely.
  VALID_AZ_INSUFFICIENT_ACTIONS = %w[WARN PAGE].freeze

  # Cost guardrails. additional_capacity is a raw
  # multiplier, so it is bounded at setup time; the per-type / per-location
  # InstanceCount ceilings page-and-skip any computed target that exceeds them.
  MAX_ADDITIONAL_CAPACITY = 2.0
  MAX_RESERVED_PER_TYPE = 1000
  MAX_RESERVED_PER_LOCATION = 5000

  # seconds. The natural re-measure cadence and the default for the operator-
  # configurable reconcile_interval input. Floored at MIN_RECONCILE_INTERVAL_SECONDS so a
  # fat-fingered tiny value cannot hammer the AWS APIs.
  RECONCILE_INTERVAL_SECONDS = 5 * 60
  MIN_RECONCILE_INTERVAL_SECONDS = 60

  # update_inputs(wait: true) polls for a lease-free moment: MAX_APPLY_ATTEMPTS tries,
  # APPLY_WAIT_POLL seconds apart, then raises if the strand is still busy.
  APPLY_WAIT_POLL = 1
  MAX_APPLY_ATTEMPTS = 120

  # Page once an AZ has been continuously short of its desired reservation for
  # this long (AWS InsufficientInstanceCapacity that just won't clear).
  UNMET_PAGE_AFTER = 24 * 60 * 60

  # The discriminating tag value carried by every ODCR this prog manages.
  MANAGED_TAG_VALUE = "automated-capacity-reservation"

  # ---------------------------------------------------------------------------
  # Entry points (class methods). Operators never edit the strand directly; setup /
  # update_inputs validate the inputs and write only the input keys (leaving any
  # running pass's state untouched). The write is lease-guarded, so it never races a
  # running pass; the change is read on the next scheduled measure (within reconcile_interval).
  # ---------------------------------------------------------------------------

  # Create-or-update. The single method setup.rb calls for every managed
  # location on every deploy. Inputs (all but location_id are also checked in
  # validate_inputs!):
  #   location_id               - the AWS Location whose Postgres workloads we hold ODCRs for.
  #   instance_families         - {family => constraint} selecting which sizes to buffer.
  #   additional_capacity       - buffer fraction added on top of current usage (floored at +3).
  #   enable_all_families       - ignore instance_families; size for every type currently in use.
  #   allowed_capacity_decrease - buffer fraction to retain over current usage when shrinking (>= additional_capacity); nil = never shrink.
  #   reconcile_interval        - seconds between natural re-measure passes; defaults to RECONCILE_INTERVAL_SECONDS, floored at MIN_RECONCILE_INTERVAL_SECONDS.
  #   remove_orphaned_reservations - if true, cancel managed ODCRs for instance types no longer eligible (e.g. a minimum_provisioned_* type that stopped being provisioned). Default false.
  #   wait                      - when true, block until the write lands (poll a lease-free moment); default false = single attempt.
  def self.setup(location_id:, instance_families:, additional_capacity:,
    enable_all_families: false, allowed_capacity_decrease: nil, reconcile_interval: RECONCILE_INTERVAL_SECONDS,
    remove_orphaned_reservations: false, min_available_az_insufficient_action: "PAGE", wait: false)
    inputs = {
      "instance_families" => instance_families,
      "enable_all_families" => enable_all_families,
      "additional_capacity" => additional_capacity,
      "allowed_capacity_decrease" => allowed_capacity_decrease,
      "reconcile_interval" => reconcile_interval,
      "remove_orphaned_reservations" => remove_orphaned_reservations,
      "min_available_az_insufficient_action" => min_available_az_insufficient_action,
    }
    # Create-if-absent here; update_inputs runs outside the transaction (its wait-loop sleeps).
    existing = DB.transaction do
      location = Location[location_id]
      fail "No such Location" unless location
      fail "Location #{location_id} is not an AWS location" unless location.aws?
      fail "no AWS credentials for location #{location_id}" unless location.location_credential_aws
      validate_inputs!(inputs)

      s = live_strand(location_id)
      return assemble(location_id:, **inputs.transform_keys(&:to_sym)) unless s
      s
    end
    update_inputs(existing, inputs, wait:)
    existing
  end

  # Create primitive. Assumes the caller (normally setup) already validated the
  # inputs and confirmed no live strand exists for the location; assemble itself
  # only inserts the row.
  def self.assemble(location_id:, instance_families:, additional_capacity:,
    enable_all_families: false, allowed_capacity_decrease: nil, reconcile_interval: RECONCILE_INTERVAL_SECONDS,
    remove_orphaned_reservations: false, min_available_az_insufficient_action: "PAGE")
    Strand.create_with_id(
      Strand.generate_uuid,
      prog: "CapacityReservation",
      label: "start",
      stack: [{
        "location_id" => location_id,
        "instance_families" => instance_families,
        "enable_all_families" => enable_all_families,
        "additional_capacity" => additional_capacity,
        "allowed_capacity_decrease" => allowed_capacity_decrease,
        "reconcile_interval" => reconcile_interval,
        "remove_orphaned_reservations" => remove_orphaned_reservations,
        "min_available_az_insufficient_action" => min_available_az_insufficient_action,
        "current_target" => {},
        "last_observed_usage" => {},
        # last_measured_at / current_usage_per_az / reconcile_pending are written
        # by the first measure.
      }],
    )
  end

  # Update operator inputs on a LIVE strand, lease-guarded so a running pass can't clobber
  # the write (we write only while the strand holds no active lease). Does not raise
  # :rebalance; inputs are read at the next scheduled measure.
  # wait: false -> single attempt, returns the strand or nil if busy/exited.
  # wait: true  -> poll until it lands (returns the strand), or raise if it stays busy.
  def self.update_inputs(strand, changes, wait: false, max_attempts: MAX_APPLY_ATTEMPTS)
    changes = changes.transform_keys(&:to_s).slice(*EDITABLE_KEYS)
    attempts = 0
    loop do
      applied = DB.transaction do
        locked = Strand
          .where(id: strand.id, exitval: nil)
          .where(Sequel[:lease] < Sequel::CURRENT_TIMESTAMP)
          .for_update
          .first
        next unless locked

        validate_inputs!(locked.stack.first.slice(*EDITABLE_KEYS).merge(changes))
        locked.stack.first.merge!(changes)
        locked.modified!(:stack)
        locked.save_changes
        locked
      end
      return applied if applied
      return nil unless wait

      attempts += 1
      fail "CapacityReservation #{strand.ubid}: strand busy; could not apply inputs within #{max_attempts} attempts" if attempts >= max_attempts
      sleep APPLY_WAIT_POLL
    end
  end

  # The live strand for the location, or nil. A strand that hopped to destroy but
  # has not yet exited still counts as live.
  def self.live_strand(location_id)
    Strand.where(prog: "CapacityReservation", exitval: nil)
      .where(Sequel.lit("stack #>> '{0,location_id}' = ?", location_id))
      .first
  end

  # Shared by setup (create) and update_inputs (edit): exactly one valid key per
  # family, valid per-family suffixes, and a bounded/finite additional_capacity.
  def self.validate_inputs!(inputs)
    enable_all = inputs["enable_all_families"]
    families = inputs["instance_families"] || {}
    fail "instance_families must be an object mapping family => constraint" unless families.is_a?(Hash)
    additional_capacity = inputs["additional_capacity"]
    fail "instance_families required" if !enable_all && families.empty?
    unless additional_capacity.is_a?(Numeric) && additional_capacity.finite? && additional_capacity >= 0 && additional_capacity <= MAX_ADDITIONAL_CAPACITY
      fail "additional_capacity must be a finite number in [0, #{MAX_ADDITIONAL_CAPACITY}]"
    end
    # Optional shrink retain-buffer fraction; must be >= additional_capacity so
    # the shrink floor (current + this fraction over current) never falls below
    # the grow target and the reservation cannot thrash. nil/absent means
    # ratchet-only (never decrease).
    unless (allowed_capacity_decrease = inputs["allowed_capacity_decrease"]).nil?
      unless allowed_capacity_decrease.is_a?(Numeric) && allowed_capacity_decrease.finite? && allowed_capacity_decrease >= additional_capacity
        fail "allowed_capacity_decrease must be a finite number >= additional_capacity (#{additional_capacity})"
      end
    end
    # Re-measure cadence in seconds; defaults to RECONCILE_INTERVAL_SECONDS when absent.
    # Floored at MIN_RECONCILE_INTERVAL_SECONDS so a tiny value cannot hammer the AWS APIs.
    reconcile_interval = inputs["reconcile_interval"] || RECONCILE_INTERVAL_SECONDS
    unless reconcile_interval.is_a?(Integer) && reconcile_interval >= MIN_RECONCILE_INTERVAL_SECONDS
      fail "reconcile_interval must be an integer >= #{MIN_RECONCILE_INTERVAL_SECONDS} seconds"
    end
    # What to do when fewer than 3 AZs are available; nil/absent defaults to WARN.
    unless (action = inputs["min_available_az_insufficient_action"]).nil? || VALID_AZ_INSUFFICIENT_ACTIONS.include?(action)
      fail "min_available_az_insufficient_action must be one of #{VALID_AZ_INSUFFICIENT_ACTIONS.join(", ")}"
    end
    unknown = families.keys - Option::AWS_FAMILY_OPTIONS
    fail "Unknown families: #{unknown}" unless unknown.empty?
    families.each do |family, constraint|
      fail "Constraint for #{family} must be an object with exactly one key" unless constraint.is_a?(Hash) && constraint.size == 1
      key, value = constraint.first
      fail "Invalid constraint key #{key} for #{family}" unless VALID_CONSTRAINT_KEYS.include?(key)
      if key == "sizes"
        fail "sizes for #{family} must be an array" unless value.is_a?(Array)
        valid = Option::VmSizes.select { it.family == family }.map { it.name.split(".", 2).last }
        value.each { |s| fail "Unknown size #{s} for family #{family}" unless valid.include?(s) }
      elsif !value.is_a?(Numeric)
        # minimum_cpu / minimum_storage / minimum_provisioned_cpu /
        # minimum_provisioned_storage all take a numeric threshold.
        fail "#{key} for #{family} must be a number"
      end
      fail "Constraint for #{family} resolves to no eligible sizes" if resolve_eligible_sizes(family, constraint).empty?
    end
  end

  # ---------------------------------------------------------------------------
  # Labels: start -> measure -> reconcile -> wait. destroy is
  # operator-only and leaks ODCRs by design.
  # ---------------------------------------------------------------------------

  label def start
    pop_if_location_gone
    hop_measure
  end

  label def measure
    pop_if_location_gone
    hop_wait if pause_set?

    azs = location_az_names
    if azs.size < 3
      report_insufficient_azs("only #{azs.size} AZ(s) in location; need >=3")
      self.current_target = {}
      self.last_observed_usage = {}
      self.current_usage_per_az = {}
      self.reconcile_pending = []
      self.last_measured_at = Time.now.to_i
      self.azs_insufficient = true
      hop_reconcile
    end
    # Reached only with >= 3 AZs: clear any stale location-wide InsufficientAZs page.
    resolve_page("InsufficientAZs")

    usage, usage_per_az = compute_current_usage
    additional_capacity = frame["additional_capacity"]
    allowed_capacity_decrease = frame["allowed_capacity_decrease"]
    previous = frame["current_target"] || {}

    new_target = {}
    last_observed = {}
    location_sum = 0
    # Biggest instance types first: grab large contiguous capacity before smaller
    # reservations fragment the AZ.
    eligible_instance_types(usage).sort_by { |type| [-(Option::VmSizes.find { it.name == type }&.vcpus || 0), type] }.each do |type|
      current = usage[type] || 0
      buffer = [(current * additional_capacity).ceil, 3].max
      target = current + buffer
      # When the new target is below the previously persisted one, shrink in a
      # single pass to a current-relative retain floor: keep an
      # allowed_capacity_decrease buffer over current usage instead of the
      # (smaller) additional_capacity grow buffer. Since allowed_capacity_decrease
      # >= additional_capacity, this floor is always >= the grow target, so the
      # reservation never settles below where growth would put it and cannot
      # thrash; it is capped at the prior total so the shrink path never grows.
      # allowed_capacity_decrease = nil means ratchet-only (never shrink).
      if (prev_total = previous.dig(type, "total")) && target < prev_total
        target = if allowed_capacity_decrease
          [current + [(current * allowed_capacity_decrease).ceil, 3].max, prev_total].min
        else
          prev_total
        end
      end

      if target > MAX_RESERVED_PER_TYPE
        page("ReservedPerTypeExceeded", "target #{target} for #{type} exceeds MAX_RESERVED_PER_TYPE=#{MAX_RESERVED_PER_TYPE}", type)
        next
      end
      # Target is within the per-type ceiling: clear any stale page for it. Done
      # before the per-location check so a per-location skip can't strand a per-type
      # page whose own condition has cleared.
      resolve_page("ReservedPerTypeExceeded", type)
      if location_sum + target > MAX_RESERVED_PER_LOCATION
        page("ReservedPerLocationExceeded", "per-location reserved sum would exceed MAX_RESERVED_PER_LOCATION=#{MAX_RESERVED_PER_LOCATION}")
        next
      end

      location_sum += target
      last_observed[type] = {"current" => current, "buffer" => target - current}
      new_target[type] = {"total" => target, "per_az" => previous.dig(type, "per_az") || {}}
      # Carry the unmet-since timestamps forward so reconcile preserves first-unmet
      # times across passes (this rebuild would otherwise reset them every cycle).
      new_target[type]["unmet_azs"] = previous.dig(type, "unmet_azs") if previous.dig(type, "unmet_azs")
    end

    self.current_target = new_target
    self.last_observed_usage = last_observed
    # Full per-AZ usage for every running type, not just the targeted ones:
    # kept intentionally as observability of what is actually running, even
    # under the strict filter where unlisted types are observed but not
    # reserved. reconcile only reads the keys it targets, so the extra entries
    # are harmless.
    self.current_usage_per_az = usage_per_az
    self.reconcile_pending = new_target.keys
    self.last_measured_at = Time.now.to_i
    self.azs_insufficient = false
    hop_reconcile
  end

  label def reconcile
    pop_if_location_gone
    hop_wait if pause_set?

    pending = frame["reconcile_pending"] || []
    if pending.empty?
      # All targeted types are reconciled. Optionally sweep ODCRs for types we no
      # longer target (current_target was just rewritten by measure this pass).
      remove_orphaned_odcrs if frame["remove_orphaned_reservations"]
      hop_wait
    end

    type = pending.first
    begin
      achieved = reconcile_instance_type(type)
      if achieved
        current_target = frame["current_target"]
        entry = current_target[type].merge("per_az" => achieved)
        # Surface (or clear) the capacity shortfall recorded by reconcile_instance_type.
        entry = @last_unmet_azs.empty? ? entry.except("unmet_azs") : entry.merge("unmet_azs" => @last_unmet_azs)
        self.current_target = current_target.merge(type => entry)
        self.reconcile_pending = pending[1..]
        # The type reconciled to completion without an AWS error: clear any stale
        # quota/unexpected-error page from a prior pass. Only here, not in the else
        # branch -- a nil achieved means the type was skipped for insufficient AZs
        # before any create/modify, so the quota/error condition was not re-tested.
        resolve_page("ODCRQuotaExceeded", type)
        resolve_page("ReconcileError", type)
      else
        # type was paged-and-skipped this pass; leave its prior per_az intact.
        self.reconcile_pending = pending[1..]
      end
      # One instance type per run; reschedule immediately to handle the next
      nap 0
    rescue Aws::EC2::Errors::RequestLimitExceeded
      # Throttling: log, back off 60s, and retry the same type (pending unchanged).
      Clog.emit("capacity reservation reconcile throttled", {capacity_reservation_throttled: {location: location.display_name, instance_type: type}})
      nap 60
    rescue Aws::EC2::Errors::ServiceError => e
      # Always log the raw AWS error, whatever we then decide to do with it.
      Clog.emit("capacity reservation reconcile error", {capacity_reservation_reconcile_error: {location: location.display_name, instance_type: type, code: e.code.to_s, message: e.message}})
      case e.code.to_s
      when /Exceeded|Limit/
        # ODCR account/region quota: page and skip the type this pass.
        page("ODCRQuotaExceeded", "ODCR quota error for #{type}: #{e.code}", type)
      when /InvalidStateTransition|IncorrectState|InvalidCapacityReservationState/
        # A reservation is mid-transition (an operator cancelled it between our
        # Describe and our Modify, or it is still pending). Recoverable and
        # already logged: skip the type this pass and let the next pass retry,
        # where create mints a fresh ODCR with a new per-pass token. No page, so
        # an operator's own cancellation does not fire an incident.
        nil
      else
        # Genuinely unexpected: page and skip the type, but keep going.
        page("ReconcileError", "unexpected AWS error for #{type}: #{e.code}", type)
      end
      self.reconcile_pending = pending[1..]
      nap 0
    end
  end

  label def wait
    when_pause_set? { nap 5 * 60 }

    if needs_rebalance?
      decr_rebalance
      hop_measure
    end

    # Clamp to >= 0: needs_rebalance? being false means elapsed < interval, but a
    # clock jump (or time passing between that check and here) could otherwise make
    # this negative and schedule the strand in the past.
    nap([(frame["reconcile_interval"] || RECONCILE_INTERVAL_SECONDS) - (Time.now.to_i - frame["last_measured_at"].to_i), 0].max)
  end

  label def destroy
    when_destroy_set? { pop "capacity reservation strand exited; ODCRs left in place" }
    nap 60 * 60 * 24 * 365
  end

  # A measure+reconcile pass is due when an operator explicitly asked for one
  # (the rebalance semaphore, raised externally) OR the natural cadence has
  # elapsed. last_measured_at is an integer UTC epoch (seconds); .to_i coerces
  # nil (first run) / anything stray to 0 (= due), so there is no Time.parse to
  # crash on.
  def needs_rebalance?
    rebalance_set? || (Time.now.to_i - frame["last_measured_at"].to_i) >= (frame["reconcile_interval"] || RECONCILE_INTERVAL_SECONDS)
  end

  # ---------------------------------------------------------------------------
  # Location / AWS client helpers.
  # ---------------------------------------------------------------------------

  def location
    @location ||= Location[frame["location_id"]]
  end

  def location_present?
    !location.nil? && location.aws? && !location.location_credential_aws.nil?
  end

  def client
    @client ||= location.location_credential_aws.client
  end

  # Full AWS AZ names (e.g. "us-east-1a"), the single canonical AZ key used
  # everywhere. location.azs self-seeds location_az from AWS on
  # first use; location_azs (the raw association) does not.
  def location_az_names
    @location_az_names ||= location.azs.map { location.name + it.az }
  end

  # If the Location (or its AWS credential) was destroyed out from under the
  # strand, page so the operator notices the now-orphaned ODCRs (discoverable by
  # the Ubicloud:LocationId tag) and pop — the strand cannot function without an
  # AWS client and never self-destroys otherwise. Cannot use
  # #page here because location is nil; tag/summary key off the frame instead.
  def pop_if_location_gone
    return if location_present?
    Prog::PageNexus.assemble(
      "CapacityReservation: location #{frame["location_id"]} is gone; its ODCRs are orphaned in AWS",
      ["CapacityReservation", "LocationGone", frame["location_id"]],
      [strand.ubid],
      severity: "warning",
    )
    pop "location is gone; capacity reservation strand exiting"
  end

  # ---------------------------------------------------------------------------
  # Sizing.
  # ---------------------------------------------------------------------------

  # Returns [usage, usage_per_az]:
  #   usage[type]            => sum of target_server_count across surviving PG
  #                             resources of that instance type.
  #   usage_per_az[type][az] => placed servers with a known AZ. Servers without an
  #                             AZ yet are counted in usage but not here; the buffer
  #                             split absorbs them.
  # The raw counts come from aggregate_usage (SQL). This only shapes them: drop sizes
  # that aren't a known VmSize (e.g. a non-AWS size), and normalize each raw subnet_az
  # to the full AZ name (legacy/backfilled rows may already hold it) so the keys match
  # eligible_azs. Kept separate from aggregate_usage so this shaping stays unit-testable
  # with plain rows (no DB / no dataset doubles).
  def compute_current_usage
    usage_raw, az_raw = aggregate_usage
    known = Option::VmSizes.map(&:name).to_set

    usage = Hash.new(0)
    usage_raw.each { |type, n| usage[type] = n.to_i if known.include?(type) }

    usage_per_az = {}
    az_raw.each do |type, subnet_az, count|
      next unless known.include?(type)
      az = location.name + subnet_az.delete_prefix(location.name)
      (usage_per_az[type] ||= Hash.new(0))[az] += count
    end

    [usage, usage_per_az]
  end

  # Aggregate current usage entirely in SQL, so a location with thousands of resources
  # costs two GROUP BY queries instead of an eager-load + per-server walk. Returns
  # [usage_raw, az_raw]:
  #   usage_raw => {target_vm_size => sum of target_server_count} over surviving resources
  #   az_raw    => [target_vm_size, subnet_az, count] rows of placed servers per AZ
  # "Surviving" = the strand still exists and there is no destroy/destroying semaphore
  # (the resource-level teardown guard, as correlated EXISTS subqueries). target_server_count
  # is standby_count + 1, with the SQL CASE generated from Option::POSTGRES_HA_OPTIONS so it
  # cannot drift from Ruby. The inner joins drop servers with no vm/nic/nic_aws_resource yet,
  # and subnet_az IS NOT NULL drops ones with no AZ -- both still counted in usage_raw via the
  # target, just not placed in az_raw. Every other placed server is counted, including one on a
  # fallback family or mid-resize; that only raises a per-AZ floor, which errs safely toward
  # holding capacity (never strands a running VM).
  def aggregate_usage
    rid = Sequel[:postgres_resource][:id]
    surviving = PostgresResource
      .where(location_id: location.id)
      .where(Strand.where(Sequel[:strand][:id] => rid).exists)
      .exclude(Semaphore.where(strand_id: rid, name: %w[destroy destroying]).exists)

    ha_count = Sequel.case(Option::POSTGRES_HA_OPTIONS.transform_values { it.standby_count + 1 }, 0, :ha_type)
    usage_raw = surviving.group(:target_vm_size).select_map([:target_vm_size, Sequel.function(:sum, ha_count).as(:count)]).to_h

    az_raw = surviving
      .join(:postgres_server, resource_id: rid)
      .join(:nic, vm_id: Sequel[:postgres_server][:vm_id])
      .join(:nic_aws_resource, id: Sequel[:nic][:id])
      .exclude(Sequel[:nic_aws_resource][:subnet_az] => nil)
      .group(Sequel[:postgres_resource][:target_vm_size], Sequel[:nic_aws_resource][:subnet_az])
      .select_map([Sequel[:postgres_resource][:target_vm_size], Sequel[:nic_aws_resource][:subnet_az], Sequel.function(:count, 1).as(:count)])

    [usage_raw, az_raw]
  end

  # Resolves a constraint object to the matching VmSize names for the family, from
  # the static size catalog (no runtime usage). Used by validate_inputs! and
  # eligible_instance_types. The "provisioned" cpu/storage variants resolve to the
  # same catalog set as their bare counterparts here; eligible_instance_types is
  # what narrows them to currently-used sizes.
  def self.resolve_eligible_sizes(family, constraint)
    family_sizes = Option::VmSizes.select { it.family == family }
    key, value = constraint.first
    case key
    when "minimum_cpu", "minimum_provisioned_cpu"
      family_sizes.select { it.vcpus >= value }.map(&:name)
    when "minimum_storage", "minimum_provisioned_storage"
      family_sizes.select { (Option::AWS_STORAGE_SIZE_OPTIONS.dig(family, it.vcpus) || [0]).max >= value }.map(&:name)
    when "sizes"
      family_sizes.select { value.include?(it.name.split(".", 2).last) }.map(&:name)
    end
  end

  # Eligible instance types depend on the mode:
  #   enable_all_families=false (strict allowlist): exactly the sizes resolved
  #     from the instance_families constraints. A catalog/threshold size (minimum_cpu
  #     / minimum_storage / sizes) with no current usage still gets the +3 pre-warm
  #     floor; a "provisioned" constraint (minimum_provisioned_cpu / _storage)
  #     covers only its matching sizes that are *currently in use* — no pre-warm.
  #     A type in current usage that is NOT listed is deliberately left uncovered.
  #   enable_all_families=true: every type observed in current usage, plus any
  #     extra sizes the constraints resolve to (pre-warm sizes not running yet on
  #     top of covering everything that is).
  def eligible_instance_types(usage)
    families = frame["instance_families"] || {}
    from_constraints = families.flat_map { |family, constraint|
      sizes = self.class.resolve_eligible_sizes(family, constraint)
      PROVISIONED_CONSTRAINT_KEYS.include?(constraint.keys.first) ? sizes & usage.keys : sizes
    }.uniq
    return from_constraints | usage.keys if frame["enable_all_families"]
    from_constraints
  end

  # ---------------------------------------------------------------------------
  # ODCR reconcile. One instance_type per label run.
  # ---------------------------------------------------------------------------

  # Aligns ODCRs for a single instance type with its target. Returns the achieved
  # per-AZ hash, or nil if the type was paged-and-skipped this pass.
  def reconcile_instance_type(type)
    # AZs AWS could not satisfy this pass, as a hash az => first-unmet epoch (set at
    # the end). reconcile reads this to surface a capacity shortfall on current_target.
    @last_unmet_azs = {}
    target_total = frame.dig("current_target", type, "total")
    return {} if target_total.nil?

    vm_size = Option::VmSizes.find { it.name == type }
    family = vm_size&.family || type.split(".", 2).first

    azs = eligible_azs(type)
    return nil if azs.nil?

    raw_usage = frame.dig("current_usage_per_az", type) || {}
    usage = azs.to_h { |az| [az, raw_usage[az] || 0] }
    existing = describe_odcrs(type)
    achieved = azs.to_h { |az| [az, existing.dig(az, :count) || 0] }
    # Already-acceptable short-circuit: if the existing reservations meet the
    # target, cover the running-VM floors, and respect both failure-domain caps
    # (single-AZ <= target/2 unless a floor forces more; two-AZ <= 5/6 target),
    # there is nothing to do — return as-is instead of reshuffling toward the ideal
    # split, which (when the ideal is unreachable) just churns Modify calls each
    # pass. A not-yet-acceptable state — short/over total, an AZ below its floor, or
    # a cap violation (e.g. a starved AZ over-concentrated into its neighbours) —
    # falls through to the reconcile steps below and is retried exactly as before.
    if achieved.values.sum == target_total &&
        azs.all? { |az| achieved[az].between?(usage[az], [target_total / 2, usage[az]].max) } &&
        achieved.values.max(2).sum <= (5 * target_total) / 6
      # Already satisfiable with no shortfall: clear any stale cap/unmet pages.
      resolve_page("FailureDomainCapUnsatisfiable", type)
      azs.each { |az| resolve_page("UnmetCapacity", type, az) }
      return achieved
    end
    allow_decrease = !frame["allowed_capacity_decrease"].nil?
    # AZs recorded in a prior pass (even at 0) are no longer "first-ever cold", so
    # grow_az adds to them linearly instead of binary-searching again — e.g. an AZ that
    # binary-searched to 0 (no capacity) last pass retries linearly from here on.
    seen = frame.dig("current_target", type, "per_az") || {}

    # Step 1: reserve current usage first. Fallible like any other
    # Create/Modify — persist what AWS accepted and retry the shortfall later.
    azs.each do |az|
      need = usage[az]
      achieved[az] = grow_az(existing, type, az, family, achieved[az], need, seen) if need > achieved[az]
    end
    # floor[az]: reserved instances already backing running servers in that AZ; we never
    # shrink an AZ below this (it is min(running count, what AWS actually reserved)).
    floor = azs.to_h { |az| [az, [usage[az], achieved[az]].min] }

    # Step 2: even split of the buffer over all AZs.
    current_sum = azs.sum { |az| usage[az] }
    buffer = [target_total - current_sum, 0].max
    share = even_split_buffer(buffer, azs, usage)
    desired = azs.to_h { |az| [az, usage[az] + share[az]] }

    # Step 3: apply the failure-domain caps.
    desired = apply_failure_caps(desired, target_total, azs, floor, usage)
    if desired.nil?
      single_cap = target_total / 2
      two_cap = (5 * target_total) / 6
      running = usage.values.sum
      busiest = usage.select { |_, v| v.positive? }.sort_by { |az, v| [-v, az] }.first(2).map { |az, v| "#{az}=#{v}" }.join(", ")
      page(
        "FailureDomainCapUnsatisfiable",
        "cannot satisfy failure-domain caps for #{type} (#{running} running, target #{target_total}, single/two-AZ caps #{single_cap}/#{two_cap}; busiest #{busiest})",
        type,
        extra_data: {
          "instance_type" => type,
          "target_total" => target_total,
          "single_az_cap" => single_cap,
          "two_az_cap" => two_cap,
          "additional_capacity" => frame["additional_capacity"],
          "eligible_azs" => azs,
          "usage_per_az" => usage,
          "reserved_per_az" => achieved,
        },
      )
      return achieved
    end
    # Caps are satisfiable this pass: clear any stale page from a prior one.
    resolve_page("FailureDomainCapUnsatisfiable", type)

    # Steps 4-5: reserve the desired split, degrading per AZ on capacity errors.
    # When allowed_capacity_decrease is set, also shrink AZs whose desired dropped
    # (never below the running-VM floor).
    azs.each do |az|
      target_az = desired[az]
      if target_az > achieved[az]
        achieved[az] = grow_az(existing, type, az, family, achieved[az], target_az, seen)
      elsif allow_decrease && target_az < achieved[az]
        # Shrink toward the running-VM floor. AWS rejects Modify(InstanceCount=0),
        # so when the floor is 0 (no running VMs and the buffer no longer reaches
        # this AZ) we don't Modify to 0 here: leave the ODCR in place so Step 6 can
        # still Modify it down if it needs the AZ for a shortfall, and cancel any
        # AZ still at 0 after Step 6 (below).
        shrunk = [target_az, floor[az]].max
        if shrunk.zero?
          achieved[az] = 0
        else
          set_count(existing, type, az, family, shrunk)
          achieved[az] = shrunk
        end
      end
    end

    # Step 6: linear top-up across all AZs, re-probing capacity
    # that may have freed up. Never exceed the single-AZ failure-domain cap.
    single_cap = target_total / 2
    loop do
      break if achieved.values.sum >= target_total
      progressed = false
      azs.each do |az|
        break if achieved.values.sum >= target_total
        next if achieved[az] >= [single_cap, floor[az]].max
        if try_set(existing, type, az, family, achieved[az] + 1)
          achieved[az] += 1
          progressed = true
        end
      end
      break unless progressed
    end

    # Fully release any AZ we intentionally drained to 0 (allow_decrease only,
    # and only where the running-VM floor is 0). AWS cannot Modify a reservation
    # to 0, so cancel it outright. An AZ that Step 6 revived to absorb a shortfall
    # has achieved > 0 and keeps its ODCR.
    if allow_decrease
      azs.each do |az|
        next unless achieved[az].zero? && (record = existing[az]) && record[:id]
        client.cancel_capacity_reservation(capacity_reservation_id: record[:id])
        existing.delete(az)
      end
    end

    # AZs that fell short of the post-caps desired (AWS InsufficientInstanceCapacity).
    # Tracked as a hash az => first-unmet epoch: an AZ still unmet keeps its original
    # timestamp, a newly-unmet one is stamped now, and recovered AZs drop out.
    # reconcile persists this on current_target (and measure carries it across passes,
    # §5). Page once an AZ has been unmet for over UNMET_PAGE_AFTER (deduped per
    # (type, az) tag, so it does not spam).
    unmet = azs.select { |az| achieved[az] < desired[az] }
    prev = frame.dig("current_target", type, "unmet_azs")
    prev = {} unless prev.is_a?(Hash)
    now = Time.now.to_i
    @last_unmet_azs = unmet.to_h { |az| [az, prev[az] || now] }
    @last_unmet_azs.each do |az, since|
      page("UnmetCapacity", "#{type} capacity unmet in #{az} for over #{UNMET_PAGE_AFTER / 3600}h", type, az) if now - since >= UNMET_PAGE_AFTER
    end
    # AZs that recovered this pass (no longer short): clear any stale UnmetCapacity page.
    (azs - @last_unmet_azs.keys).each { |az| resolve_page("UnmetCapacity", type, az) }
    achieved
  end

  # Cancel managed ODCRs for instance types we no longer target. Cause-agnostic: it
  # describes ALL of this location's managed ODCRs (the same tag filter as
  # describe_odcrs, minus the InstanceType filter) and cancels any whose type is not
  # in the freshly-measured current_target — whether the type dropped because a
  # minimum_provisioned_* size stopped being provisioned or because the operator
  # removed it from the config. Currently-eligible types (all `sizes` and
  # minimum_* catalog pre-warms included) are in current_target by construction and
  # are never touched. Only invoked when remove_orphaned_reservations is set; a
  # per-cancel rescue keeps an already-cancelled/racing ODCR from aborting the sweep
  # (it is re-attempted next cycle).
  def remove_orphaned_odcrs
    targeted = (frame["current_target"] || {}).keys
    # An empty target sweeps EVERY managed ODCR for the location -- a deliberate full
    # wind-down when remove_orphaned_reservations is set and nothing is eligible. The one
    # exception is the InsufficientAZs safety path: measure zeroes the target there while
    # the workload is still running and AZs are transiently < 3, so never mass-cancel in
    # that case (azs_insufficient guards it). NOTE: with the flag set, a constraint that
    # resolves to nothing -- including a fat-fingered one -- cancels all reservations.
    return if targeted.empty? && frame["azs_insufficient"]
    next_token = nil
    loop do
      response = client.describe_capacity_reservations({
        filters: [
          {name: "tag:Ubicloud", values: [Config.provider_resource_tag_value]},
          {name: "tag:Ubicloud:Managed", values: [MANAGED_TAG_VALUE]},
          {name: "tag:Ubicloud:LocationId", values: [frame["location_id"]]},
          {name: "state", values: ["active", "pending"]},
        ],
        next_token:,
      })
      response.capacity_reservations.each do |cr|
        next if targeted.include?(cr.instance_type)
        Clog.emit("capacity reservation orphan cancelled", {capacity_reservation_orphan_cancelled: {location: location.display_name, instance_type: cr.instance_type, az: cr.availability_zone}})
        client.cancel_capacity_reservation(capacity_reservation_id: cr.capacity_reservation_id)
      rescue Aws::EC2::Errors::ServiceError => e
        Clog.emit("capacity reservation orphan cancel error", {capacity_reservation_orphan_cancel_error: {location: location.display_name, instance_type: cr.instance_type, code: e.code.to_s}})
      end
      next_token = response.next_token
      break if next_token.nil?
    end
  end

  # Eligible AZ set for an instance type: AZs offering the type intersected with
  # the location's AZs. Pages and returns nil if < 3.
  def eligible_azs(type)
    offered = []
    next_token = nil
    loop do
      response = client.describe_instance_type_offerings({
        location_type: "availability-zone",
        filters: [{name: "instance-type", values: [type]}],
        next_token:,
      })
      offered.concat(response.instance_type_offerings.map(&:location))
      next_token = response.next_token
      break if next_token.nil?
    end

    azs = (location_az_names & offered).sort
    if azs.size < 3
      report_insufficient_azs("only #{azs.size} AZ(s) available for #{type}; need >=3", type)
      return nil
    end
    # >= 3 AZs offer the type now: clear any stale per-type InsufficientAZs page.
    resolve_page("InsufficientAZs", type)
    azs
  end

  # Either page or just log when fewer than 3 AZs are available (location-wide in
  # measure, or for a single type in eligible_azs), per the
  # min_available_az_insufficient_action input. Defaults to PAGE: only an explicit
  # "WARN" logs rather than pages, so a pre-existing strand (whose stack predates
  # this input, leaving it nil) keeps the original page-on-insufficient behavior.
  def report_insufficient_azs(summary, *extra)
    if frame["min_available_az_insufficient_action"] == "WARN"
      Clog.emit("capacity reservation insufficient azs", {capacity_reservation_insufficient_azs: {location: location.display_name, summary:, tags: extra}})
    else
      page("InsufficientAZs", summary, *extra)
    end
  end

  # Describe this prog's active/pending ODCRs for an instance type, keyed by full
  # AZ name. Follows the next_token pagination loop; on duplicates
  # for a (type, az) pair, deterministically keeps the largest InstanceCount.
  def describe_odcrs(type)
    result = {}
    next_token = nil
    loop do
      response = client.describe_capacity_reservations({
        filters: [
          {name: "tag:Ubicloud", values: [Config.provider_resource_tag_value]},
          {name: "tag:Ubicloud:Managed", values: [MANAGED_TAG_VALUE]},
          {name: "tag:Ubicloud:LocationId", values: [frame["location_id"]]},
          {name: "tag:Ubicloud:InstanceType", values: [type]},
          {name: "state", values: ["active", "pending"]},
        ],
        next_token:,
      })
      response.capacity_reservations.each do |cr|
        existing = result[cr.availability_zone]
        if existing.nil? || cr.total_instance_count > existing[:count]
          result[cr.availability_zone] = {id: cr.capacity_reservation_id, count: cr.total_instance_count}
        end
      end
      next_token = response.next_token
      break if next_token.nil?
    end
    result
  end

  # Grow the reservation for one (type, az) from `from` toward `to`. We optimistically
  # request the whole target in one call; on an AZ-capacity refusal we degrade. We
  # binary-search only the FIRST time we ever reconcile a cold AZ (no existing ODCR and
  # not yet in `seen`, the prior pass's per_az) — to find the ceiling fast. Every later
  # pass grows linearly: from a known reservation floor, or from 0 for an AZ that
  # binary-searched to 0 last pass (so a no-capacity AZ just probes 1, 2, ... cheaply).
  # Returns the count AWS actually accepted.
  def grow_az(existing, type, az, family, from, to, seen)
    return from if to <= from
    # Common case: the full target is available in one call.
    return to if try_set(existing, type, az, family, to)

    best = from
    # Smallest count we asked AWS for while degrading (the one-shot `to` already
    # failed above). Logged alongside the shortfall so achieved:0/smallest_attempt:1
    # reads unambiguously as "AWS refused even a single instance", instead of
    # leaving the reader to infer from the algorithm how far down grow_az probed.
    smallest_attempt = to
    if existing.dig(az, :id).nil? && !seen.key?(az)
      # First-ever cold AZ: binary-search the largest acceptable count below the target.
      low = from + 1
      high = to - 1
      while low <= high
        mid = (low + high) / 2
        smallest_attempt = [smallest_attempt, mid].min
        if try_set(existing, type, az, family, mid)
          best = mid
          low = mid + 1
        else
          high = mid - 1
        end
      end
    else
      # Known floor, or a previously-seen AZ (incl. one that hit 0): add linearly.
      ((from + 1)...to).each do |n|
        smallest_attempt = [smallest_attempt, n].min
        break unless try_set(existing, type, az, family, n)
        best = n
      end
    end
    # We only reach here when the one-shot try_set(to) was refused with
    # InsufficientInstanceCapacity (the only error try_set swallows) and we
    # degraded to `best` (< to) via binary/linear probing — or could not grow at
    # all. That refusal is otherwise silent, so log the shortfall (covers the
    # one-shot, binary, and linear paths alike).
    Clog.emit("capacity reservation insufficient capacity", {capacity_reservation_insufficient_capacity: {location: location.display_name, instance_type: type, az:, requested: to, achieved: best, smallest_attempt:}})
    best
  end

  # Create-or-modify the ODCR for one (type, az) to InstanceCount=count, swallowing
  # the expected InsufficientInstanceCapacity. Returns true on success.
  def try_set(existing, type, az, family, count)
    set_count(existing, type, az, family, count)
    true
  rescue Aws::EC2::Errors::InsufficientInstanceCapacity
    false
  end

  # Create the ODCR if none exists for (type, az) yet, else modify it in place.
  # Mutates `existing` so subsequent calls in the same pass modify rather than
  # create. Modify (the rebalance/steady-state path) carries no ClientToken.
  #
  # The Create ClientToken is salted with both the requested `count` and
  # last_measured_at. The `count` is load-bearing: one pass issues several Creates
  # for the same (type, az) at *different* counts (the one-shot try_set(to), then
  # binary-search / linear probes), and AWS rejects reusing a token with different
  # params (IdempotentParameterMismatch), so each distinct-size Create needs its
  # own token; an identical-size retry still hits the same token and stays
  # idempotent. last_measured_at makes the token fresh every pass (cadence or
  # :rebalance): AWS keeps a token bound to the reservation it created and advises
  # against reuse across requests
  # (https://docs.aws.amazon.com/ec2/latest/devguide/ec2-api-idempotency.html), so
  # a token fixed per (type, az, count) would stay bound even after the ODCR is
  # cancelled and a later Create would return that *cancelled* reservation; the
  # per-pass salt sidesteps that (a cancelled reservation carries an older salt).
  def set_count(existing, type, az, family, count)
    if (record = existing[az]) && record[:id]
      client.modify_capacity_reservation(capacity_reservation_id: record[:id], instance_count: count)
      record[:count] = count
    else
      response = client.create_capacity_reservation(
        instance_type: type,
        instance_platform: "Linux/UNIX",
        availability_zone: az,
        tenancy: "default",
        instance_count: count,
        end_date_type: "unlimited",
        instance_match_criteria: "open",
        tag_specifications: [{
          resource_type: "capacity-reservation",
          tags: Util.aws_tags("capacity-reservation-#{type}-#{az}", {
            "component" => "clickgres",
            "Ubicloud:Managed" => MANAGED_TAG_VALUE,
            "Ubicloud:LocationId" => frame["location_id"],
            "Ubicloud:Family" => family,
            "Ubicloud:InstanceType" => type,
            "Ubicloud:AvailabilityZone" => az,
          }),
        }],
        client_token: Digest::SHA256.hexdigest("cap-res:#{frame["location_id"]}:#{type}:#{az}:#{count}:#{frame["last_measured_at"]}"),
      )
      existing[az] = {id: response.capacity_reservation.capacity_reservation_id, count:}
    end
  end

  # Distribute `buffer` evenly across azs: each gets base = buffer / |azs|; the
  # `buffer % |azs|` extras go to the busiest AZs first, ties broken by full AZ
  # name ascending so the split is deterministic.
  def even_split_buffer(buffer, azs, usage)
    base = buffer / azs.size
    extras = buffer % azs.size
    share = azs.to_h { |az| [az, base] }
    azs.sort_by { |az| [-(usage[az] || 0), az] }.first(extras).each { |az| share[az] += 1 }
    share
  end

  # Cap per-AZ concentration so the reserved spread matches the HA spread we reserve for
  # (none/async/sync clusters place 1/2/3 servers across distinct AZs): no AZ above
  # floor(target_total/2), no two AZs above floor(5*target_total/6). The constants assume
  # an even none/async/sync mix and optimal per-cluster spread, giving total servers
  # S = x/3*(1+2+3) = 2x with shares none=1/6, async=1/3, sync=1/2. Worst-case single-AZ
  # occupancy = 1/6*1 + 1/3*1/2 + 1/2*1/3 = 1/2 (50%); worst-case two-AZ = 1/6 + 1/3*1 +
  # 1/2*2/3 = 5/6 (~83%). The running-VM floor (current usage, which we can't move) wins
  # over the cap, so in practice only the buffer is constrained. Returns the adjusted
  # split, or nil if unsatisfiable (caller pages and keeps just the floors).
  def apply_failure_caps(desired, target_total, azs, floor, usage)
    single_cap = target_total / 2
    two_cap = (5 * target_total) / 6
    desired = azs.to_h { |az| [az, desired[az]] }
    busiest = azs.sort_by { |az| [-(usage[az] || 0), az] }

    # Single-AZ cap: shave each AZ above max(single_cap, floor) and redistribute.
    surplus = 0
    azs.each do |az|
      cap = [single_cap, floor[az]].max
      if desired[az] > cap
        surplus += desired[az] - cap
        desired[az] = cap
      end
    end
    surplus = redistribute(desired, busiest, single_cap, surplus)
    return nil if surplus > 0

    # Two-AZ cap: if the two highest AZs exceed two_cap, shave (down to floors)
    # and redistribute to the rest.
    top_two = azs.sort_by { |az| [-desired[az], az] }.first(2)
    combined = top_two.sum { |az| desired[az] }
    if combined > two_cap
      excess = combined - two_cap
      top_two.each do |az|
        break if excess <= 0
        take = [desired[az] - floor[az], excess].min
        if take > 0
          desired[az] -= take
          excess -= take
        end
      end
      shaved = (combined - two_cap) - excess
      others = busiest.reject { |az| top_two.include?(az) }
      shaved = redistribute(desired, others, single_cap, shaved)
      return nil if excess > 0 || shaved > 0
    end

    desired
  end

  # Add `surplus` units one at a time to AZs that are still below single_cap, in
  # the given order. Returns whatever could not be placed.
  def redistribute(desired, order, single_cap, surplus)
    while surplus > 0
      recipient = order.find { |az| desired[az] < single_cap }
      break unless recipient
      desired[recipient] += 1
      surplus -= 1
    end
    surplus
  end

  def page(reason, summary, *extra, extra_data: {})
    kwargs = {severity: "warning"}
    kwargs[:extra_data] = extra_data unless extra_data.empty?
    Prog::PageNexus.assemble(
      "CapacityReservation #{location.display_name}: #{summary}",
      ["CapacityReservation", reason, location.display_name, *extra],
      [strand.ubid],
      **kwargs,
    )
  end

  # Resolve the page #page would have raised for the same (reason, *extra), if one
  # is currently active. Symmetric to #page; from_tag_parts returns nil when nothing
  # is active, so &.incr_resolve is a safe no-op. Called wherever a paged condition
  # is rechecked and found clear. Two pages are intentionally NOT auto-resolved and
  # so are never passed here: LocationGone (the strand pops; its ODCRs are genuinely
  # orphaned) and ReservedPerLocationExceeded (a hard cost guardrail breach) -- both
  # warrant a human ack. A per-type/per-AZ page whose subject vanishes entirely (e.g.
  # a type whose last VM disappears under enable_all_families) is not revisited and
  # so is not auto-resolved either; an operator acks those manually.
  def resolve_page(reason, *extra)
    Page.from_tag_parts("CapacityReservation", reason, location.display_name, *extra)&.incr_resolve
  end
end
