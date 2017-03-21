#!/bin/bash
cp ../../pgglaskugel .
sudo docker build -t=pgglaskugelcentos7 .
sudo docker run -it -v /sys/fs/cgroup:/sys/fs/cgroup:ro --privileged pgglaskugelcentos7
