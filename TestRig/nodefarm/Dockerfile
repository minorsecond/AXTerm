FROM python:3.12-alpine
COPY ax25station.py netrom.py nodefarm.py /app/
WORKDIR /app
ENV FARM_SEED=1
CMD ["sh","-c","python3 -u nodefarm.py 172.28.99.10 8010 --seed ${FARM_SEED}"]
