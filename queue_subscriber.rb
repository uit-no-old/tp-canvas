require 'bunny'

# Connect to the RabbitMQ server
connection = Bunny.new(hostname: 'fulla.uit.no', user: 'sua', pass: 'shaun')
connection.start

# Create our channel and config it
channel = connection.create_channel

# Get exchange
exchange = channel.fanout('tp-course-pub', {durable: true})

# Get our queue
queue = channel.queue('tp-course-client_test', durable:true, exclusive:false)
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
