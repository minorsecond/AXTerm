FROM python:3.12-alpine
COPY ax25station.py ka_node.py /app/
WORKDIR /app
CMD ["python3", "-u", "ka_node.py", "172.28.99.10", "8010", "--call", "K0EPI", "--ssid", "6", "--alias", "DRL"]
