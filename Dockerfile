FROM ubuntu:18.04

RUN apt update && apt install -y python3 python3-pip
RUN apt install -y nodejs npm
RUN pip3 install pipenv

RUN mkdir chat_app
COPY . chat_app
WORKDIR chat_app
ENV LC_ALL C.UTF-8
ENV LANG C.UTF-8
RUN pipenv install --skip-lock

ARG db_pass 

RUN pipenv run yoyo apply -f -b --database postgresql://postgres:$db_pass@127.0.0.1 ./migrations
