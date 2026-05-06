# frozen_string_literal: true

class Clover
  # Audit-log action strings written by postgres_inject_failure.
  # Defined here (not in helpers/general.rb's SUPPORTED_ACTIONS) so the entire
  # failure-injection feature stays in clickhouse-fork-only files.
  POSTGRES_FAILURE_INJECTION_ACTIONS = %w[
    inject_failure_os_shutdown
    inject_failure_pg_restart
    inject_failure_pg_service_stop
  ].freeze

  def postgres_inject_failure(pg, failure_type)
    server = pg.representative_server
    raise CloverError.new(400, "InvalidRequest", "No representative server found for this database") unless server

    sshable = server.vm.sshable
    # Audit the attempt before issuing the SSH command so the audit row survives
    # even if the command (or the SSH connection) fails — the request itself
    # is the auditable event.
    write_failure_injection_audit_log(pg, failure_type)
    no_audit_log
    case failure_type
    when "pg_service_stop"
      sshable.cmd("sudo pg_ctlcluster :version main stop -m smart", version: server.version)
    when "os_shutdown"
      begin
        sshable.cmd("sudo shutdown -h now")
      rescue *::Sshable::SSH_CONNECTION_ERRORS, ::Sshable::SshError
        # Expected: SSH connection drops when the machine goes down.
        nil
      end
    else # "pg_restart" — least consequential default; OpenAPI enum constrains failure_type to one of three values
      sshable.cmd("sudo pg_ctlcluster :version main restart", version: server.version)
    end

    204
  end

  private

  # Writes an audit_log row directly, bypassing helpers/general.rb's
  # SUPPORTED_ACTIONS guard. Keeps the SUPPORTED_ACTIONS list (which upstream
  # actively edits) untouched in this fork.
  def write_failure_injection_audit_log(pg, failure_type)
    action = "inject_failure_#{failure_type}"
    DB[:audit_log].returning(nil).insert(
      project_id: @project.id,
      ubid_type: ::PostgresResource.ubid_type,
      action:,
      subject_id: current_account.id,
      object_ids: Sequel.pg_array([pg.id], :uuid),
    )
  end
end
