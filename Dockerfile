FROM mcr.microsoft.com/azure-cli
RUN apk add python3 python3-dev py3-pip build-base libressl-dev musl-dev libffi-dev jq
RUN pip3 install pip --upgrade
RUN pip3 install certbot
RUN mkdir /etc/letsencrypt
COPY ./* /home/
# The following expects the env variables DOMAIN, EMAIL and AKV
CMD ["bash", "-c", "/home/certbot_generate.sh"]