import os
import boto3

sns = boto3.client("sns")


def open_to_world(detail):
    """Return the rules in this API call that allow 0.0.0.0/0."""
    found = []
    perms = detail.get("requestParameters", {}).get("ipPermissions", {}).get("items", [])
    for perm in perms:
        for rng in perm.get("ipRanges", {}).get("items", []):
            if rng.get("cidrIp") == "0.0.0.0/0":
                found.append(f"{perm.get('ipProtocol')} {perm.get('fromPort')}-{perm.get('toPort')}")
    return found


def lambda_handler(event, context):
    detail = event["detail"]
    name = detail.get("eventName")
    who = detail.get("userIdentity", {})

    if name == "AuthorizeSecurityGroupIngress":
        rules = open_to_world(detail)
        if not rules:
            return {"alert": False}          # a normal, scoped rule: stay quiet
        group = detail.get("requestParameters", {}).get("groupId")
        title = f"Security group {group} opened to 0.0.0.0/0: {', '.join(rules)}"
    else:
        title = f"{name} by {who.get('type')}"   # e.g. ConsoleLogin by Root

    issuer = who.get("sessionContext", {}).get("sessionIssuer", {}).get("arn")
    message = "\n".join([
        title,
        f"Who: {who.get('arn')}",
        f"Role behind the session: {issuer}",
        f"Source IP: {detail.get('sourceIPAddress')}",
        f"User agent: {detail.get('userAgent')}",
        f"Time: {detail.get('eventTime')}  Region: {detail.get('awsRegion')}",
        f"CloudTrail event ID: {detail.get('eventID')}",
    ])
    sns.publish(TopicArn=os.environ["TOPIC_ARN"], Subject="Lab security alert", Message=message)
    print(message)
    return {"alert": True}