#require 'httparty'
#require 'sequel'
#require 'sqlite3'
require 'bunny'

# Connect to the RabbitMQ server
connection = Bunny.new(hostname: 'fulla.uit.no', user: 'sua', pass: 'shaun')
connection.start

# Create our channel and config it
channel = connection.create_channel
channel.prefetch(1)

# Get exchange
exchange = channel.fanout('tp-coursepub')

# Get our queue
queue = channel.queue('hellotest_receiverclient', durable:true, exclusive:false)
queue.bind(exchange)

begin
    puts ' [*] Waiting for messages. To exit press CTRL+C'
    queue.subscribe(block: true, manual_ack: true) do |delivery_info, _properties, body|
        puts " [x] Received #{body}"
        channel.ack(delivery_info.delivery_tag)
    end
rescue Interrupt => _
    connection.close
    exit(0)
end
