#!/bin/sh
set -e
echo "Validating AWS Credentials..."
python3 scripts/validate_aws_credentials.py ${AWS_ACCOUNT_ID}

# Get a local AWS profile for interacting with remote tfstate stored with Lariat
echo "Initializing Installer..."
python3 scripts/kms/decrypt_and_store_remote_tfstate_profile.py ${AWS_ACCOUNT_ID} > lariat_profile.json

cat lariat_profile.json | jq -r .AccessKeyId | xargs -I {} aws configure set aws_access_key_id {} --profile lariat
cat lariat_profile.json | jq -r .SecretAccessKey | xargs -I {} aws configure set aws_secret_access_key {} --profile lariat
cat lariat_profile.json | jq -r .SessionToken | xargs -I {} aws configure set aws_session_token {} --profile lariat

echo "Initializing Terraform..."
terraform init -reconfigure \
              -backend-config="key=${AWS_ACCOUNT_ID}/athena/terraform.tfstate" \
              -backend-config="bucket=lariat-customer-installation-tfstate" \
              -backend-config="region=us-east-2" \
	      -backend-config="access_key=$(aws configure get aws_access_key_id --profile lariat)" \
	      -backend-config="secret_key=$(aws configure get aws_secret_access_key --profile lariat)" \
	      -backend-config="token=$(aws configure get aws_session_token --profile lariat)"

python3 athena_installer.py


if [ -n "$1" ] && [ "$1" = "uninstall" ]; then
    echo "Uninstalling Lariat..."
    terraform destroy -auto-approve
    echo "Lariat uninstalled!"
else
    echo "Running installation..."
    terraform apply -auto-approve
    echo "Installation successful!"
fi
