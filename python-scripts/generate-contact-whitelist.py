import os
import csv
import json


def generate_contact_whitelist(
    csv_path=os.environ.get("CONTACT_WHITELIST_FILE_PATH"),
    dist_path=os.environ.get("CONTACT_WHITELIST_DIST_PATH"),
):
    with open(csv_path, "r") as f:
        reader = csv.DictReader(f, ["relationship", "name", "email"])
        values = set([row["email"] for row in reader])
    domains = list([value for value in values if value.startswith("@")])
    emails = list([value for value in values if value not in domains])
    domains.sort()
    emails.sort()
    with open(os.path.join(dist_path, "contact-whitelist-protonmail.txt"), "w") as f:
        f.write(generate_protonmail_filter(domains, emails))
    with open(os.path.join(dist_path, "contact-whitelist-gmail.txt"), "w") as f:
        f.write(generate_gmail_filter(domains, emails))


def generate_protonmail_filter(domains, emails):
    return f"""require "fileinto";

if not anyof(
\taddress :is "from" {json.dumps(emails)},
\taddress :domain "from" {json.dumps(domains)}
)
{{
    fileinto "miscellaneous";
}}
"""


def generate_gmail_filter(domains, emails):
    values = domains + emails
    return f"NOT {{{' '.join([f'from:{value}' for value in values])}}}"


generate_contact_whitelist()
