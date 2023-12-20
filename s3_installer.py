from collections import defaultdict
from ruamel.yaml import YAML

import json
import os
import sys
import subprocess

def validate_agent_config():
    yaml = YAML()
    with open("s3_agent.yaml") as agent_config_file:
        agent_config = yaml.load(agent_config_file)

    assert "buckets" in agent_config
    assert "databases" in agent_config
    assert isinstance(agent_config["databases"], dict)

    for bucket in agent_config["buckets"].keys():
        assert isinstance(agent_config["buckets"][bucket], list)

    print(f"Agent Config Validated: \n {json.dumps(agent_config, indent=4)}")

def get_target_s3_buckets():
    yaml = YAML()

    with open("s3_agent.yaml") as agent_config_file:
        agent_config = yaml.load(agent_config_file)

    return list(agent_config["buckets"].keys())

if __name__ == '__main__':
    validate_agent_config()
    target_buckets = get_target_athena_databases()
    print(f"Installing lariat to S3 buckets {target_buckets}")

    lariat_api_key = os.environ.get("LARIAT_API_KEY")
    lariat_application_key = os.environ.get("LARIAT_APPLICATION_KEY")
    aws_region = os.environ.get("AWS_REGION")

    lariat_sink_aws_access_key_id = os.getenv("LARIAT_TMP_AWS_ACCESS_KEY_ID")
    lariat_sink_aws_secret_access_key = os.getenv("LARIAT_TMP_AWS_SECRET_ACCESS_KEY")

    tf_env = {
        "lariat_api_key": lariat_api_key,
        "lariat_application_key": lariat_application_key,
        "lariat_sink_aws_access_key_id": lariat_sink_aws_access_key_id,
        "lariat_sink_aws_secret_access_key": lariat_sink_aws_secret_access_key,
        "aws_region": aws_region,
    }

    print("Passing configuration through to terraform")
    with open("lariat.auto.tfvars.json", "w") as f:
        json.dump(tf_env, f)
