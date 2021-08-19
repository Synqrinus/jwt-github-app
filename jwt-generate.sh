#!/usr/bin/env bash
set -eo pipefail
# Generate JWT for Github App
#
# Inspired by implementation by Will Haley at:
#   http://willhaley.com/blog/generate-jwt-with-bash/
# From:
#   https://stackoverflow.com/questions/46657001/how-do-you-create-an-rs256-jwt-assertion-with-bash-shell-scripting

thisdir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

app_id="$APP_ID"
app_private_key="$PRIVATE_KEY"
lifetime="$LIFETIME"
repo=${GITHUB_REPOSITORY:?Missing required GITHUB_REPOSITORY environment variable}

[[ ! -z "$INPUT_REPO" ]] && repo=$INPUT_REPO

echo "::debug::App ID $app_id"
echo "::debug::App Secret $app_private_key"
echo "::debug::lifetime $lifetime"
# Shared content to use as template
header='{
    "alg": "RS256",
    "typ": "JWT"
}'
payload_template='{}'

build_payload() {
        jq -c \
                --arg iat_str "$(date +%s)" \
                --arg app_id "${app_id}" \
                --arg lifetime_str "${lifetime}" \
        '
        ($lifetime_str | tonumber) as $lifetime
        | ($iat_str | tonumber) as $iat
        | .iat = $iat
        | .exp = ($iat + $lifetime)
        | .iss = ($app_id | tonumber)
        ' <<< "${payload_template}" | tr -d '\n'
}

b64enc() { openssl enc -base64 -A | tr '+/' '-_' | tr -d '='; }
json() { jq -c . | LC_CTYPE=C tr -d '\n'; }
rs256_sign() { openssl dgst -binary -sha256 -sign <(printf '%s\n' "$1"); }

payload=$(build_payload) || return
signed_content="$(json <<<"$header" | b64enc).$(json <<<"$payload" | b64enc)"
sig=$(printf %s "$signed_content" | rs256_sign "$app_private_key" | b64enc)
jwt="${signed_content}.${sig}"

check_id=$(curl -s -H "Authorization: Bearer ${signed_content}.${sig}" -H "Accept: application/vnd.github.v3+json" https://api.github.com/app | jq '.id')

if [[ ! "$check_id" == "$app_id" ]]; then
    echo "::error::Could not generate JWT token"
    exit 1
fi

echo "::debug::JWT Token successfully generated."

installation_id=$(curl -s \
-H "Authorization: Bearer ${jwt}" \
-H "Accept: application/vnd.github.machine-man-preview+json" \
https://api.github.com/repos/${repo}/installation | jq -r .id)

if [ "$installation_id" = "null" ]; then
  echo "Unable to get installation ID. Is the GitHub App installed on ${repo}?"
  exit 1
fi

token=$(curl -s -X POST \
-H "Authorization: Bearer ${jwt}" \
-H "Accept: application/vnd.github.machine-man-preview+json" \
https://api.github.com/app/installations/${installation_id}/access_tokens | jq -r .token)

if [ "$token" = "null" ]; then
  echo "Unable to generate installation access token"
  exit 1
fi

echo "::set-output name=token::${token}"
