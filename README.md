# TP-Canvas sync

Authors: Håvard Pedersen & Øyvind Guttvik Årnes

A tool for syncing timetables from TP to Canvas.

Set `CANVAS_TOKEN`, `DB_USER`, `DB_PASS`, `MQ_USER`, `MQ_PASS` as environment variable

Use ruby 2.5.1, Recommend https://github.com/rbenv/rbenv to install Ruby.

Migrate database postgres: `sequel -m . postgres://[username]:[password]@uit-ita-sua-tp-canvas-db.postgres.database.azure.com/tp_canvas_[dev/prod]?sslmode=require`

Note: special characters must be url-encoded in username/password

Sequel migrations: https://github.com/jeremyevans/sequel/blob/master/doc/migration.rdoc

To run: `ruby test_publish.py --help`

## Installation/setup tp-canvas.uit.no

#### Yum
Add `proxy=http://swproxy.uit.no:3128`  to `/etc/yum.conf`  
Install packages: `sudo yum install -y git openssl-devel readline-devel zlib-devel postgresql-devel`


#### Add 'sua' user
`sudo adduser sua`

#### Add to  .bashrc (as sua)
```
export http_proxy=http://swproxy.uit.no:3128
export https_proxy=https://swproxy.uit.no:3128
export TMPDIR=/home/sua/tmp
```

#### Install rbenv (as sua)
Follow instructions: https://github.com/rbenv/rbenv

#### Checkout and test script (as sua)
`git config --global http.proxy http://swproxy.uit.no:3128`  
`git clone git@bitzer.uit.no:sua/tp-canvas.git /home/sua/tp-canvas`

Set ENV: `CANVAS_TOKEN DB_USER DB_PASS MQ_USER MQ_PASS`

in `/home/sua/tp-canvas`:  
`gem install bundler`  
`bundle install`  
`ruby tp-canvas-sync.rb -m` <- monitor message queue

#### Setup service(systemd)
`sudo cp /home/sua/tp-canvas/tp-canvas.service /lib/systemd/system/`  
edit `/lib/systemd/system/tp-canvas.service`, set env values  
`sudo systemctl enable tp-canvas.service`  
`sudo systemctl start tp-canvas.service`

Service status: `sudo systemctl status tp-canvas.service`

#### SSH tunnel (Azure database)
As of 22.05.2018 the Postgres database is not available from tp-canvas.uit.no.
A temporary workaround is using a ssh-tunnel via another computer.
This is not a acceptable solution and should be fixed.

ssh-tunnel from Øyvind's workstation  
`ssh -R 5432:uit-ita-sua-tp-canvas-db.postgres.database.azure.com:5432 oya027@tp-canvas.uit.no`
