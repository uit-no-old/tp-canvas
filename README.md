# TP-Canvas sync

WORK IN PROGRESS

Auth: Øyvind Årnes

Will take one course schedule from TP and insert into Canvas.

Set `CANVAS_TOKEN`, `DB_USER`, `DB_PASS`, `MQ_USER`, `MQ_PASS` as environment variable

Use ruby 2.5.1, I recommend https://github.com/rbenv/rbenv to install Ruby.

Gems used: `httparty` `sequel` `pg` `optparse`  

Migrate database postgres: `sequel -m . postgres://[username]:[password]@uit-ita-sua-tp-canvas-db.postgres.database.azure.com/tp_canvas_[dev/prod]?sslmode=require`

Note: special characters must be url-encoded in username/password

Sequel migrations: https://github.com/jeremyevans/sequel/blob/master/doc/migration.rdoc

To run: `ruby test_publish.py --help`
