#!/bin/sh

info()
{
  echo -e "\e[1m${1}\e[0m"
}

error()
{
  echo -e "\e[1m\e[31m${1}\e[0m"
}

warn()
{
  echo -e "\e[1m\e[33m${1}\e[0m"
}



info "Info message"
warn "Warn message"
error "Error message"

