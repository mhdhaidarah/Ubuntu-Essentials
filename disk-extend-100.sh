#!/usr/bin/env bash
sudo growpart /dev/sda 3
sudo pvresize /dev/sda3
sudo lvextend -l +100%FREE -r /dev/ubuntu-vg/ubuntu-lv
