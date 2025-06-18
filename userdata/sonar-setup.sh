#!/bin/bash

# Backup and update sysctl config
cp /etc/sysctl.conf /root/sysctl.conf_backup
cat <<EOT > /etc/sysctl.conf
vm.max_map_count=262144
fs.file-max=65536
EOT
sysctl -p

# Update security limits
cp /etc/security/limits.conf /root/sec_limit.conf_backup
cat <<EOT >> /etc/security/limits.conf
sonar   -   nofile   65536
sonar   -   nproc    4096
EOT

# Install dependencies
apt update -y
apt install -y openjdk-17-jdk wget unzip curl gnupg2 apt-transport-https ca-certificates lsb-release zip net-tools nginx

# Verify Java
java -version

# Install PostgreSQL
wget -q https://www.postgresql.org/media/keys/ACCC4CF8.asc -O - | apt-key add -
sh -c 'echo "deb http://apt.postgresql.org/pub/repos/apt/ $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list'
apt update -y
apt install -y postgresql postgresql-contrib

# Start PostgreSQL and set password
systemctl enable postgresql
systemctl start postgresql
echo "postgres:admin123" | chpasswd

# Setup SonarQube DB
sudo -u postgres psql <<EOF
CREATE USER sonar WITH PASSWORD 'admin123';
CREATE DATABASE sonarqube OWNER sonar;
GRANT ALL PRIVILEGES ON DATABASE sonarqube TO sonar;
EOF

# Download & configure SonarQube
mkdir -p /sonarqube
cd /sonarqube
curl -O https://binaries.sonarsource.com/Distribution/sonarqube/sonarqube-10.5.1.90531.zip
unzip sonarqube-10.5.1.90531.zip -d /opt/
mv /opt/sonarqube-10.5.1.90531 /opt/sonarqube

# Create sonar user
groupadd sonar
useradd -c "SonarQube User" -d /opt/sonarqube -g sonar sonar
chown -R sonar:sonar /opt/sonarqube

# Configure SonarQube properties
cp /opt/sonarqube/conf/sonar.properties /root/sonar.properties_backup
cat <<EOT > /opt/sonarqube/conf/sonar.properties
sonar.jdbc.username=sonar
sonar.jdbc.password=admin123
sonar.jdbc.url=jdbc:postgresql://localhost/sonarqube
sonar.web.host=0.0.0.0
sonar.web.port=9000
sonar.web.javaAdditionalOpts=-server
sonar.search.javaOpts=-Xmx1G -Xms1G -XX:+HeapDumpOnOutOfMemoryError
sonar.log.level=INFO
sonar.path.logs=logs
EOT

# Create systemd service
cat <<EOT > /etc/systemd/system/sonarqube.service
[Unit]
Description=SonarQube service
After=network.target postgresql.service

[Service]
Type=forking
ExecStart=/opt/sonarqube/bin/linux-x86-64/sonar.sh start
ExecStop=/opt/sonarqube/bin/linux-x86-64/sonar.sh stop
User=sonar
Group=sonar
Restart=always
LimitNOFILE=65536
LimitNPROC=4096

[Install]
WantedBy=multi-user.target
EOT

# Reload and enable SonarQube
systemctl daemon-reload
systemctl enable sonarqube

# Nginx Reverse Proxy Setup
rm -rf /etc/nginx/sites-enabled/default
rm -rf /etc/nginx/sites-available/default
cat <<EOT > /etc/nginx/sites-available/sonarqube
server {
    listen 80;
    server_name sonarqube.groophy.in;

    access_log  /var/log/nginx/sonar.access.log;
    error_log   /var/log/nginx/sonar.error.log;

    location / {
        proxy_pass http://127.0.0.1:9000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto http;
    }
}
EOT

ln -s /etc/nginx/sites-available/sonarqube /etc/nginx/sites-enabled/sonarqube
systemctl enable nginx
systemctl restart nginx

# Firewall
ufw allow 80,9000,9001/tcp

# Reboot for changes to take effect
echo "Rebooting in 30 seconds..."
sleep 30
reboot
