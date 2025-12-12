#!/bin/bash
set -e

# simple bootstrapping: install python3, pip, flask, boto3; write a small Flask upload app
apt update -y
apt install -y python3 python3-pip nginx
pip3 install flask boto3

# create app folder
mkdir -p /var/www/html
cd /var/www/html

# write the Flask app that uploads to S3
cat << 'EOF' > /var/www/html/upload_app.py
from flask import Flask, request, render_template_string
import boto3
import os
from botocore.exceptions import ClientError

app = Flask(__name__)

S3_BUCKET = os.getenv("S3_BUCKET")
if not S3_BUCKET:
    raise ValueError("S3_BUCKET environment variable is not set")

s3 = boto3.client("s3", region_name="${region}")

HTML = """
<!doctype html>
<title>File Upload</title>
<h1>Upload a file to S3</h1>
<form method=post enctype=multipart/form-data>
  <input type=file name=file>
  <input type=submit value=Upload>
</form>
{{ message }}
"""

@app.route("/", methods=["GET", "POST"])
def upload_file():
    message = ""
    if request.method == "POST":
        f = request.files.get("file")
        if f:
            key = f.filename
            try:
                s3.upload_fileobj(f, S3_BUCKET, key)
                message = f"<p>Successfully uploaded '{key}' to S3 bucket {S3_BUCKET}.</p>"
            except ClientError as e:
                message = f"<p>Upload failed: {str(e)}</p>"
    return render_template_string(HTML, message=message)

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
EOF

# set environment variable for S3 bucket (this will be injected by Terraform via user-data templating)
echo "S3_BUCKET=${s3_bucket}" >> /etc/environment
source /etc/environment

# systemd service to run the Flask app
cat << 'EOF' > /etc/systemd/system/uploadapp.service
[Unit]
Description=Flask Upload App
After=network.target

[Service]
User=root
WorkingDirectory=/var/www/html
EnvironmentFile=-/etc/environment
ExecStart=/usr/bin/python3 /var/www/html/upload_app.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable uploadapp
systemctl start uploadapp

# configure nginx as a reverse proxy (optional, allows HTTP on port 80)
cat << 'EOF' > /etc/nginx/sites-available/uploadapp
server {
    listen 80;
    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
EOF

ln -sf /etc/nginx/sites-available/uploadapp /etc/nginx/sites-enabled/uploadapp
rm -f /etc/nginx/sites-enabled/default
systemctl restart nginx

echo "bootstrap complete"
