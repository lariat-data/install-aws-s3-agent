from collections import defaultdict
from ruamel.yaml import YAML

import json
import os
import sys
import subprocess
import re
import boto3

def validate_agent_config():
    yaml = YAML()
    with open("s3_agent.yaml") as agent_config_file:
        agent_config = yaml.load(agent_config_file)

    assert "buckets" in agent_config

    for bucket in agent_config["buckets"].keys():
        assert isinstance(agent_config["buckets"][bucket], list)

    print(f"Agent Config Validated: \n {json.dumps(agent_config, indent=4)}")

def get_target_s3_buckets():
    yaml = YAML()

    with open("s3_agent.yaml") as agent_config_file:
        agent_config = yaml.load(agent_config_file)

    buckets = list(agent_config["buckets"].keys())
    bucket_prefixes = defaultdict(list)

    for bucket in buckets:
        for config in agent_config["buckets"][bucket]:
            bucket_prefixes[bucket].append(config["prefix"])

    return bucket_prefixes

if __name__ == '__main__':
    validate_agent_config()
    target_bucket_prefixes = get_target_s3_buckets()

    # get existing event notification state for target s3 buckets
    s3Client = boto3.client('s3')
    expected_bucket_owner = os.getenv("AWS_ACCOUNT_ID", None)
    assert expected_bucket_owner is not None, "Please provide a valid AWS_ACCOUNT_ID"

    new_s3_notifications = defaultdict(list)
    existing_s3_notifications_sns = {}
    existing_s3_notifications_lambda = {}

    for bucket, prefixes in target_bucket_prefixes.items():
        response = s3Client.get_bucket_notification_configuration(
            Bucket=bucket,
            ExpectedBucketOwner=expected_bucket_owner
        )

        if any([k in response for k in ["TopicConfigurations", "LambdaFunctionConfigurations", "QueueConfigurations", "EventBridgeConfiguration"]]):
            # Check if any monitored prefixes are configured to notify an SNS Topic
            if "TopicConfigurations" in response:
                for config in response['TopicConfigurations']:
                    matches = {}
                    notifying_events = config["Events"]
                    is_notifying_on_object_create = [e for e in notifying_events if "s3:ObjectCreated" in e]

                    if is_notifying_on_object_create and 'Filter' in config:
                        prefix_rules = [r for r in config['Filter']['Key']['FilterRules'] if r['Name'].lower() == 'prefix']
                        for rule in prefix_rules:
                            for p in prefixes:
                                if re.match(p, rule['Value']):
                                    matches[p] = config['TopicArn']
                    else:
                        # No prefix filtering in place.
                        print(f"No prefix or suffix filtering in place for SNS notifications for bucket {bucket}")

                    if matches:
                        for matched_prefix, topic in matches.items():
                            print(f"Bucket {bucket} is notifying topic {topic} for created objects in prefix {matched_prefix}. Installer will preserve existing configuration")

                            existing_s3_notifications_sns[bucket] = {matched_prefix: topic}

            if "LambdaFunctionConfigurations" in response:
                for config in response['LambdaFunctionConfigurations']:
                    matches = {}
                    notifying_events = config["Events"]
                    is_notifying_on_object_create = [e for e in notifying_events if "s3:ObjectCreated" in e]

                    if is_notifying_on_object_create and 'Filter' in config:
                        prefix_rules = [r for r in config['Filter']['Key']['FilterRules'] if r['Name'].lower() == 'prefix']
                        for rule in prefix_rules:
                            for p in prefixes:
                                if re.match(p, rule['Value']):
                                    matches[p] = config['LambdaFunctionArn']

                    else:
                        # No prefix filtering in place.
                        print(f"No prefix or suffix filtering in place for lambda notifications for bucket {bucket}")
                    if matches:
                        for matched_prefix, func in matches.items():
                            print(f"Bucket {bucket} is notifying lambda {func} for created objects in prefix {matched_prefix}. Installer will preserve existing configuration")

                            existing_s3_notifications_lambda[bucket] = {matched_prefix: func}

            # check if any prefix mentioned in yaml is not covered by existing notifications, and add them to news
            for prefix in prefixes:
                if prefix in existing_s3_notifications_lambda[bucket].keys():
                    continue

                if prefix in existing_s3_notifications_sns[bucket].keys():
                    continue

                print(f"Bucket {bucket} has no notifications on created objects in monitored prefix {prefix}. Installer will set up SNS notifications")
                new_s3_notifications[bucket].append(prefix)
        else:
            print(f"Bucket {bucket} has no notifications on created objects. Installer will set up SNS notifications for prefix {prefix}")
            new_s3_notifications[bucket] = prefixes

    target_buckets = list(set([t for t in target_bucket_prefixes.keys()]))
    print(f"Installing lariat to S3 buckets {target_buckets}")

    lariat_api_key = os.environ.get("LARIAT_API_KEY")
    lariat_application_key = os.environ.get("LARIAT_APPLICATION_KEY")
    aws_region = os.environ.get("AWS_REGION")

    lariat_payload_source= os.environ.get("LARIAT_PAYLOAD_SOURCE", "s3")

    lariat_sink_aws_access_key_id = os.getenv("LARIAT_TMP_AWS_ACCESS_KEY_ID")
    lariat_sink_aws_secret_access_key = os.getenv("LARIAT_TMP_AWS_SECRET_ACCESS_KEY")

    tf_env = {
        "lariat_api_key": lariat_api_key,
        "lariat_application_key": lariat_application_key,
        "lariat_sink_aws_access_key_id": lariat_sink_aws_access_key_id,
        "lariat_sink_aws_secret_access_key": lariat_sink_aws_secret_access_key,
        "lariat_payload_source": lariat_payload_source,
        "aws_region": aws_region,
        "target_s3_buckets": target_buckets,
        "target_s3_bucket_prefixes": dict(new_s3_notifications),
        "existing_s3_bucket_notifications_sns": existing_s3_notifications_sns,
        "existing_s3_bucket_notifications_lambda": existing_s3_notifications_lambda,
    }

    print("Passing configuration through to terraform")
    with open("lariat.auto.tfvars.json", "w") as f:
        json.dump(tf_env, f)
