ENV["POSTGRES_SERVICE_PROJECT_ID"] = "6cd8de39-9beb-86d2-b7d2-580f446ce00a"
ENV["ENABLE_FAILURE_INJECTION"] = "true"
ENV["ALLOW_WEB_SSH"] = "true"
# TODO(andrey.chudnovskiy): Enable when the first override is added
if ENV["RACK_ENV"] != "test"
  ENV["AWS_PROFILE"] = "pg-dev-postgresqladmindev"
  ENV["AWS_POSTGRES_IAM_ACCESS"] = "true"
  ENV["CLOVER_ADMIN_DEVELOPMENT_NO_WEBAUTHN"] = "true"
end
