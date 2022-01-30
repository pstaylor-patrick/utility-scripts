import boto3
import sys


def main():
    dynamodb_table = boto3.resource("dynamodb").Table("rt-survey-recipients")
    with dynamodb_table.batch_writer() as batch:
        for item in dynamodb_table.scan().get("Items", []):
            batch.delete_item(Key={"pk": item.get("pk"), "sk": item.get("sk")})


main()
