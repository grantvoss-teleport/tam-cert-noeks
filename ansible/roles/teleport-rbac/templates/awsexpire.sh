zmodload zsh/datetime
PROFILE="Admin-west"
AWS_TIMEZONE="America/Los_Angeles"
expires=$(aws configure export-credentials --profile "$PROFILE" | jq -r '.Expiration')

# Remove the colon from the timezone offset so date/zsh can read it (e.g., +00:00 -> +0000)
clean_expires="${expires%:*}${expires##*:}"

# Convert to Pacific Time
# %z handles the +0000 offset, AWS_TIMEZONE handles the output
expires_timezone=$(TZ="$AWS_TIMEZONE" date -j -f "%Y-%m-%dT%H:%M:%S%z" "$clean_expires" +"%Y-%m-%d %I:%M:%S %p %Z")

echo "UTC Expiry: $expires"
echo "Timezone Expiry: $expires_timezone"