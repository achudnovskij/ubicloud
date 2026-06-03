# frozen_string_literal: true

class Prog::Postgres::PostgresTimelineNexus
  module PrependMethods
    # The base #take_backup unconditionally dereferences postgres_timeline.leader.vm.sshable.
    # In the billing-deactivate flow, the leader can vanish between the wal-g sentinel
    # landing and our next wake-up (billing_deactivate_wait_backup polls the same
    # sentinel and hops into destroy as soon as it appears, which destroys the servers).
    # Clear the on-demand backup signal so we don't crash-loop on nil.vm and return
    # to #wait — wait will self-destruct the orphan timeline once it's old enough.
    def take_backup
      if postgres_timeline.leader.nil?
        decr_take_backup_for_scale_down
        hop_wait
      end

      super
    end
  end
end
