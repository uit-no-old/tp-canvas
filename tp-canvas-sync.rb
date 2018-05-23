require 'httparty'
require 'sequel'
require 'bunny'
require 'trollop'
require 'logger'
require 'raven'

database_url_dev = "postgres://uit-ita-sua-tp-canvas-db.postgres.database.azure.com/tp_canvas_dev?sslmode=require"
database_url_prod = "postgres://uit-ita-sua-tp-canvas-db.postgres.database.azure.com/tp_canvas_prod?sslmode=require"
DB = Sequel.connect(database_url_dev, user: ENV["DB_USER"], password: ENV["DB_PASS"])

class CanvasCourse < Sequel::Model
  one_to_many :canvas_events
end

class CanvasEvent < Sequel::Model
  many_to_one :canvas_course
end

class AppLog
  def self.log
    if @logger.nil?
      @logger = Logger.new("tp-canvas.log")
      @logger.level = Logger::DEBUG
    end
    @logger
  end
end


$threads = []

TpBaseUrl = "https://tp.uio.no/uit/ws"
CanvasBaseUrl = "https://uit.test.instructure.com/api/v1"
Headers = {"Authorization"  => "Bearer #{ENV['CANVAS_TOKEN']}"}

# create event in Canvas and DB-
def add_event_to_canvas(event, db_course, courseid, canvas_course_id)
  if Thread.current.thread_variable_get(:seppuku)
    Thread.current.exit
  end
  location = ""
  @map_url = ""
  if event["room"]
   location = event["room"].collect{|room| "#{room['buildingid']} #{room['roomid']}"}.join(", ")
   event["room"].each do |room|
     @map_url += "<a href=#{URI.escape("https://uit.no/mazemaproom?room_name=#{room["buildingid"]} #{room["roomid"]}&zoom=20")}> #{room["buildingid"]} #{room["roomid"]}</a><br>"
   end
   @map_url.rstrip!
  end
  @staff = ""
  if event["staffs"]
    @staff = event["staffs"].collect{|staff| "#{staff['firstname']} #{staff['lastname']}"}.join("<br>")
  end
  @recording = false
  if event["tags"] and event["tags"].grep(/Mediasite/).any?
    @recording = true
  end

  options = { headers: Headers,
              query:
              {calendar_event:
                {
                  context_code: "course_#{canvas_course_id}",
                  title: "#{courseid} #{event['summary']}",
                  description: ERB.new(File.read("event_description.html.erb")).result(binding),
                  start_at: event["dtstart"],
                  end_at: event["dtend"],
                  location_name: location
                }
              }
            }
  res = HTTParty.post(CanvasBaseUrl + "/calendar_events.json", options)

  if res.code == 201
    AppLog.log.info("Event created in Canvas: #{courseid} #{event['summary']}")
    db_event = CanvasEvent.new
    db_event.canvas_id = res["id"]
    db_event.save
    db_course.add_canvas_event(db_event)
  end
end

# delete all canvas events for a course in DB
def delete_canvas_events(course)
  course.canvas_events.each do |event|
    if Thread.current.thread_variable_get(:seppuku)
      Thread.current.exit
    end
    res = HTTParty.delete(CanvasBaseUrl + "/calendar_events/#{event.canvas_id}.json", headers: Headers)
    if res.code == 200
      event.delete
      AppLog.log.info("Event deleted in Canvas: #{course.name} - #{event.canvas_id}")
    end
  end
end

# generic method to add a TP-timetable to one or more Canvas courses.
# courses - json for Canvas courses
# tp_activities - json for TP-timetable
# courseid - Course id - e.g INF-1100
def add_timetable_to_canvas(courses, tp_activities, courseid)
  return if tp_activities.nil?
  courses.each do |course|
    db_course = CanvasCourse.find_or_create(canvas_id: course["id"])
    db_course.name = course["name"]
    db_course.course_code = course["course_code"]
    db_course.sis_course_id = course["sis_course_id"]
    db_course.save
    # delete old events if any
    delete_canvas_events(db_course)


    #find matching timetable
    actid = course["sis_course_id"].split("_").last
    act_timetable = tp_activities.select{|t| t["actid"] == actid}
    act_timetable.each do |at|
      at["eventsequences"].each do |es|
        es["events"].each do |event|
          # add to canvas calendar
          add_event_to_canvas(event, db_course, courseid, course["id"])

          # delete from timetable
          tp_activities.delete_if{|t| t["actid"] == actid}


        end
      end
    end
  end
  return tp_activities
end


# 1 used if there is only one course in canvas for a given course-code
# 2 Also used to add any remaining activities from TP to "main" course in Canvas
# canvas_course - json for course in Canvas
# timetable - json for TP-timetable
# courseid - Course id - e.g INF-1100
# delete_old - used for case 2.
def add_timetable_to_one_canvas_course(canvas_course, timetable, courseid, delete_old=true)
  db_course = CanvasCourse.find_or_create(canvas_id: canvas_course["id"])
  db_course.name = canvas_course["name"]
  db_course.course_code = canvas_course["course_code"]
  db_course.sis_course_id = canvas_course["sis_course_id"]
  db_course.save

  if delete_old
    delete_canvas_events(db_course)
  end

  return if timetable.nil?

  timetable.each do |t|
    t["eventsequences"].each do |eventsequence|
      eventsequence["events"].each do |event|
        add_event_to_canvas(event, db_course, courseid, canvas_course["id"])
      end
    end
  end
end


# update entire semester in Canvas
# semester - semester string "YY[h|v]" e.g "18v"
def full_sync(semester)
  # fetch all active courses from TP
  tp_courses = HTTParty.get(TpBaseUrl + "/course?id=186&sem=#{semester}&times=1")
  tp_courses["data"].each_slice(4) do |slice|
    threads = []
    slice.each do |tp_course|
      threads << Thread.new{update_one_tp_course_in_canvas(tp_course["id"], semester, tp_course["terminnr"])}
    end
    threads.each do |t|
      t.join
    end
  end

end

def remove_one_tp_course_from_canvas(courseid, semesterid, termnr)

  sis_semester = make_sis_semester(semesterid)

  CanvasCourse.where(Sequel.lit("sis_course_id like '%#{courseid}%#{sis_semester}%'")).each do |course|
    delete_canvas_events(course)
  end

end

# this wont work. termnr should be versionnr. Not available from TP
def make_sis_course_id(courseid, semesterid, termnr)
  sis_course_id = ""
  if semesterid[-1].upcase == "H"
    sis_course_id = "#{courseid}_#{termnr}_20#{semesterid[0..1]}_HØST"
  else
    sis_course_id = "#{courseid}_#{termnr}_20#{semesterid[0..1]}_VÅR"
  end
  return sis_course_id
end


def make_sis_semester(semesterid)
  sis_semester = ""
  if semesterid[-1].upcase == "H"
    sis_semester = "20#{semesterid[0..1]}_HØST"
  else
    sis_semester = "20#{semesterid[0..1]}_VÅR"
  end
  return sis_semester
end


# update one course in Canvas
# courseid - String e.g "INF-1100"
# semesterid - String e.g "18v"
# termnr - Int/String
def update_one_tp_course_in_canvas(courseid, semesterid, termnr)

  # fetch TP timetable
  timetable = HTTParty.get(URI.escape(TpBaseUrl + "/1.4/?id=#{courseid}&sem=#{semesterid}&termnr=#{termnr}"))

  # fetch Canvas courses
  canvas_courses = HTTParty.get(URI.escape(CanvasBaseUrl + "/accounts/1/courses?search_term=#{courseid}&per_page=100"), headers: Headers)

  # remove all with wrong semester - can probably be removed
  sis_semester = make_sis_semester(semesterid)
  canvas_courses.keep_if{|c| c["sis_course_id"] and c["sis_course_id"].upcase.include?(sis_semester.upcase)}
  return if canvas_courses.empty?

  #ony one course in Canvas
  if canvas_courses.length == 1
    #put everything here
    tdata = nil
    unless timetable["data"].nil?
      tdata = timetable["data"]["group"].to_a.concat(timetable["data"]["plenary"].to_a)
    end
    add_timetable_to_one_canvas_course(canvas_courses.first, tdata, timetable["courseid"])

  # more than one course in Canvas. Do we have other variants here?
  else

    # find UE - fellesundervisning? Can there be more than one?
    ue = canvas_courses.select{|c| c["sis_course_id"].include?("UE_")}

    # find UA - gruppeundervisning?
    ua = canvas_courses.select{|c| c["sis_course_id"].include?("UA_")}

    group_timetable = timetable["data"]["group"]

    processed_group_timetable = add_timetable_to_canvas(ua, group_timetable, timetable['courseid'])

    plenary_timetable = timetable["data"]["plenary"]

    processed_plenary_timetable = add_timetable_to_canvas(ue, plenary_timetable, timetable['courseid'])

    # add rest of group events to first ue - should we do this?
    #add_timetable_to_one_canvas_course(ue.first, processed_group_timetable, timetable["courseid"], false) if ue.first

  end


end


# Subscribe to message queue and update when courses change
def queue_subscriber
  # Connect to the RabbitMQ server
  connection = Bunny.new(hostname: 'fulla.uit.no', user: ENV["MQ_USER"], pass: ENV["MQ_PASS"])
  connection.start

  # Create our channel and config it
  channel = connection.create_channel
  channel.prefetch(1)

  # Get exchange
  exchange = channel.fanout('tp-course-pub', durable: true)

  # Get our queue
  queue = channel.queue('tp-canvas-sync', durable:true, exclusive:false)
  queue.bind(exchange)


  # subscribe to queue
  queue.subscribe(block: true, manual_ack: true) do |delivery_info, properties, body|
      AppLog.log.debug(" [x] Received #{body}")
      $threads.each do |t|
        AppLog.log.debug("Active thread - #{t[:name]} - #{t.object_id}")
      end
      channel.ack(delivery_info.delivery_tag)
      course = JSON.parse(body)
      if ["BOOKING", "EKSAMEN"].include?(course["id"]) == false # ignore BOKKING and EKSAMEN
        course_key = "#{course["id"]}-#{course["terminnr"]}-#{course["semesterid"]}"
        $threads.each do |t|
          if t[:name] == course_key
            # tell thread to kill itself
            t.thread_variable_set(:seppuku, true)
            # wait untill dead
            while true
              if t.alive? == false
                AppLog.log.debug("killed thread: #{t[:name]} - #{t.object_id}")
                break
              end
              sleep 1
            end
          end
        end
        # max 4 threads
        sleep 1 while $threads.length > 3
        # add ned thread for course-semester-termnr combination
        $threads << Thread.new(course["id"], course["semesterid"], course["terminnr"]) do |t_id, t_semesterid, t_terminnr|
          begin
            Thread.current[:name] = "#{t_id}-#{t_terminnr}-#{t_semesterid}"
            update_one_tp_course_in_canvas(t_id, t_semesterid, t_terminnr)
          rescue Exception => e
            Raven.capture_exception(e)
            AppLog.log.error(e)
          ensure
            $threads.delete(Thread.current)
          end
        end
      end


  end

end


opts = Trollop::options do
  banner "Command-Line utility to sync timetables from TP to Canvas.\nUsage: ruby #{File.basename(__FILE__)} [options]"
  opt :semester, "Sync full semester <s>=YY[h/v] e.g '--semester 18v'", short: "-s", long: "--semester", type: :string                   # flag --monkey, default false
  opt :course, "Sync course '--course <courseid> <semester> <termnr>' e.g --course MED-3601 18h 1", short: "-c", long: "--course", type: :strings        # string --name <s>, default nil
  opt :remove_course, "Remove course from Canvas '--course <courseid> <semester> <termnr>'  e.g --remove-course MED-3601 18h 1", short: "-r", long: "--remove-course", type: :strings
  opt :mq, "Monitor message queue for updates", short: "-m", long: "--message-queue"
end
if opts.keys.count{|k| k.to_s.include?("_given")} > 1
  puts "Use only one option"
  exit
end
if opts[:course_given]
  update_one_tp_course_in_canvas(opts[:course][0], opts[:course][1], opts[:course][2])
elsif opts[:remove_course_given]
  remove_one_tp_course_from_canvas(opts[:remove_course][0], opts[:remove_course][1], opts[:remove_course][2])
elsif opts[:semester_given]
  full_sync(opts[:semester])
elsif opts[:mq_given]
  queue_subscriber
else

end
