#!/bin/sh

wait_for_file() {
  local file=$1
  while [ ! -f "$file" ]; do
    sleep 1
    echo "Waiting for $file..."
  done
}

for file in vault_unseal_key vault_root_token; do
  wait_for_file "$file"
done

cat <<EOF
{
  "vault_unseal_key": "$(cat vault_unseal_key | tr -d '\n')",
  "vault_root_token": "$(cat vault_root_token | tr -d '\n')"
}
EOF