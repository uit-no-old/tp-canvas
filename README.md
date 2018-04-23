# TP-Canvas sync

WORK IN PROGRESS

Auth: Øyvind Årnes

Will take one course schedule from TP and insert into Canvas.

Set `CANVAS_TOKEN` as environment variable

Use ruby 2.5.1, I recommend https://github.com/rbenv/rbenv to install Ruby.

Gems used: `httparty` `sequel` `sqlite3`

Migrate database: `sequel -m . sqlite://canvas.sqlite3` https://github.com/jeremyevans/sequel/blob/master/doc/migration.rdoc

To run: `ruby test_publish.py`

Course code, semester and term number is hard-coded at the moment.
