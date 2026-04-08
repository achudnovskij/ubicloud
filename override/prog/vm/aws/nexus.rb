# frozen_string_literal: true

class Prog::Vm::Aws::Nexus
  module PrependMethods
    def create_role_policy
      if Config.aws_s3_custom_builds_bucket_names
        custom_build_s3_policy_document = {
          Version: "2012-10-17",
          Statement: [
            {
              Sid: "Statement1",
              Effect: "Allow",
              Action: [
                "s3:GetBucketLocation",
                "s3:GetObject",
                "s3:GetObjectVersion",
                "s3:ListBucket",
              ],
              Resource: Config.aws_s3_custom_builds_bucket_names.flat_map { |b|
                ["arn:aws:s3:::#{b}", "arn:aws:s3:::#{b}/*"]
              },
            },
          ],
        }.to_json

        ignore_invalid_entity do
          iam_client.create_policy({policy_name: custom_build_s3_policy_name, policy_document: custom_build_s3_policy_document})
        end
      end

      super
    end

    def attach_role_policy
      if Config.aws_s3_custom_builds_bucket_names && (policy = custom_build_s3_policy)
        ignore_invalid_entity do
          iam_client.attach_role_policy({role_name:, policy_arn: policy.arn})
        end
      end

      super
    end

    def cleanup_roles
      if (policy = custom_build_s3_policy)
        ignore_invalid_entity do
          iam_client.detach_role_policy({role_name:, policy_arn: policy.arn})
        end

        ignore_invalid_entity do
          iam_client.delete_policy({policy_arn: policy.arn})
        end
      end

      super
    end

    def custom_build_s3_policy
      @custom_build_s3_policy ||= begin
        marker = nil
        found_policy = nil
        loop do
          response = iam_client.list_policies(scope: "Local", marker:, max_items: 100)
          policy = response.policies.find { |p| p.policy_name == custom_build_s3_policy_name }
          if policy
            found_policy = policy
            break
          end

          break unless response.is_truncated
          marker = response.marker
        end
        found_policy
      end
    end

    def custom_build_s3_policy_name
      "#{vm.name}-custom-build-s3-access"
    end
  end
end
