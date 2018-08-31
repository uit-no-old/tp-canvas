require 'httparty'
require 'sequel'
require 'bunny'
require 'trollop'
require 'logger'
require 'raven'
require 'pp'
require 'time'
require 'nokogiri'

database_url_dev = "mysql2://appbase.uit.no/tp_canvas_dev"
database_url_prod = "mysql2://appbase.uit.no/tp_canvas_prod"
DB = Sequel.connect(database_url_prod, user: ENV["DB_USER"], password: ENV["DB_PASS"])

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
CanvasBaseUrl = "https://uit.instructure.com/api/v1"
#CanvasBaseUrl = "https://uit.test.instructure.com/api/v1" # Canvas test
Headers = {"Authorization"  => "Bearer #{ENV['CANVAS_TOKEN']}"}

MqHost = "fulla.uit.no"
MqExchange = "tp-course-pub"
MqQueue = "tp-canvas-sync"
#MqQueue = "tp-canvas-sync-test" #Test queue

# compare tp_event and canvas_event
# check for changes in title, location, start-date, end-date, staff and recording tag
# tp_event json from tp-ws
# canvas_event json from canvas-ws
# courseid - Course id - e.g INF-1100 (required for title)
def tp_event_equals_canvas_event?(tp_event, canvas_event, courseid)
  if Thread.current.thread_variable_get(:seppuku)
    Thread.current.exit
  end
  #canvas workflow_state - deleted in canvas
  return false if canvas_event["workflow_state"] == "deleted"

  #title
  title = "#{courseid} #{tp_event['summary']}"
  #puts "|#{title}| - |#{canvas_event["title"]}|"
  return false if title != canvas_event["title"]

  #location
  location = ""
  if tp_event["room"]
    location = tp_event["room"].collect{|room| "#{room['buildingid']} #{room['roomid']}"}.join(", ")
  end
  #puts "|#{location}| - |#{canvas_event["location_name"]}|"
  return false if location != canvas_event["location_name"]
  
  #dates
  return false if Time.parse(tp_event["dtstart"]) != Time.parse(canvas_event["start_at"])
  return false if Time.parse(tp_event["dtend"]) != Time.parse(canvas_event["end_at"])
  #puts "|#{Time.parse(tp_event["dtstart"])}| - |#{Time.parse(canvas_event["start_at"])}|"
  #puts "|#{Time.parse(tp_event["dtend"])}| - |#{Time.parse(canvas_event["end_at"])}|"

  # fetch recording and staff from canvas_event
  doc = Nokogiri::HTML(canvas_event["description"])
  span = doc.at_css("span#description-meta")
  return false if span.nil?
  meta = JSON.parse(span.child.text)

  #staff
  staff_arr = []
  if tp_event["staffs"]
    staff_arr = tp_event["staffs"].collect{|staff| "#{staff['firstname']} #{staff['lastname']}"}
  end
  #puts "|#{staff_arr.sort}| - |#{meta["staff"].sort}|"
  return false if staff_arr.sort != meta["staff"].sort
  
  #recording tag
  recording = (!tp_event["tags"].nil? and tp_event["tags"].grep(/Mediasite/).any?)
  #puts "|#{recording}| - |#{meta["recording"]}|"
  return false if recording != meta["recording"]

  true
end

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
  @staff_arr = []
  if event["staffs"]
    @staff = event["staffs"].collect{|staff| "#{staff['firstname']} #{staff['lastname']}"}.join("<br>")
    @staff_arr = event["staffs"].collect{|staff| "#{staff['firstname']} #{staff['lastname']}"}
  end
  @recording = false
  if event["tags"] and event["tags"].grep(/Mediasite/).any?
    @recording = true
  end
  @description_meta = {recording: @recording, staff: @staff_arr}
  
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

    db_event = CanvasEvent.new
    db_event.canvas_id = res["id"]
    db_event.save
    AppLog.log.info("Event created in Canvas: #{courseid} #{event['summary']} - canvas id: #{db_event.canvas_id} - internal id: #{db_event.id}")
    db_course.add_canvas_event(db_event)
  end
end

# delete single canvas event in DB and Canvas WS
def delete_canvas_event(event)
  if Thread.current.thread_variable_get(:seppuku)
    Thread.current.exit
  end
  res = HTTParty.delete(CanvasBaseUrl + "/calendar_events/#{event.canvas_id}.json", headers: Headers)
  if res.code == 200 # OK
    event.delete
    AppLog.log.info("Event deleted in Canvas: #{event.canvas_course.name} - canvas id: #{event.canvas_id} internal id: #{event.id}")
  elsif res.code == 404 #NOT FOUND
    event.delete
    AppLog.log.info("Event missing in Canvas: #{event.canvas_course.name} - canvas id: #{event.canvas_id} internal id: #{event.id}")
  elsif res.code == 401 #UNAUTHORIZED
    # is the event deleted in Canvas?
    canvas_event = HTTParty.get(CanvasBaseUrl + "/calendar_events/#{event.canvas_id}", headers: Headers)
    if canvas_event["workflow_state"] == "deleted"
      event.delete
      AppLog.log.info("Event workflow_status is 'deleted' in Canvas: #{event.canvas_course.name} - canvas id: #{event.canvas_id} internal id: #{event.id}")  
    end
  end
end

# delete all canvas events for a course in DB and Canvas WS
def delete_canvas_events(course)
  course.canvas_events.each do |event|
    delete_canvas_event(event)
  end
end

# generic method to add a TP-timetable to one or more Canvas courses.
# courses - json for Canvas courses
# tp_activities - json for TP-timetable
# courseid - Course id - e.g INF-1100
def add_timetable_to_canvas(courses, tp_activities, courseid)
  return if tp_activities.nil?
  courses.each do |course|
    #find matching timetable
    actid = course["sis_course_id"].split("_").last
    act_timetable = tp_activities.select{|t| t["actid"] == actid}
    add_timetable_to_one_canvas_course(course, act_timetable, courseid)
  end
end


# used if there is only one course in canvas for a given course-code
# canvas_course - json for course in Canvas
# timetable - json for TP-timetable
# courseid - Course id - e.g INF-1100
def add_timetable_to_one_canvas_course(canvas_course, timetable, courseid)
  db_course = CanvasCourse.find_or_create(canvas_id: canvas_course["id"])
  db_course.name = canvas_course["name"]
  db_course.course_code = canvas_course["course_code"]
  db_course.sis_course_id = canvas_course["sis_course_id"]
  db_course.save

  #empty tp-timetable
  if timetable.nil?
    delete_canvas_events(db_course)
    return
  end

  # put tp-events in array
  tp_events = []  
  timetable.each do |t|
    t["eventsequences"].each do |eventsequence|
      eventsequence["events"].each do |event|
        tp_events << event
      end
    end
  end

  # fetch Canvas events found in db
  db_course.canvas_events.each do |canvas_event_db|
    canvas_event_ws = HTTParty.get(CanvasBaseUrl + "/calendar_events/#{canvas_event_db.canvas_id}", headers: Headers)
    found_matching_tp_event = false
    
    #look for match between canvas and tp
    tp_events.each_with_index do |tp_event, i|
      if tp_event_equals_canvas_event?(tp_event, canvas_event_ws, courseid)
        # no need to update, remove tp_event from array of events
        tp_events.delete_at(i)
        found_matching_tp_event = true  
        AppLog.log.debug("Event match in TP and Canvas - no update needed: #{db_course.name} - canvas id: #{canvas_event_db.canvas_id} internal id: #{canvas_event_db.id}")
        break
      end
    end
    
    if found_matching_tp_event == false
      #puts "Have to delete canvas_event: #{canvas_event_ws["id"]} "
      delete_canvas_event(canvas_event_db)
      #canvas_delete_counter += 1
    end
  end

  # add remaining tp_events in Canvas
  tp_events.each do |event|
    add_event_to_canvas(event, db_course, courseid, canvas_course["id"])
  end
  
end

# remove local courses that have been removed from Canvas
# canvas_courses - array - canvas sis-ids
def remove_local_courses_missing_from_canvas(canvas_courses)
  canvas_courses.each do |course_id|
    local_course = CanvasCourse.where(sis_course_id: course_id).first
    local_course.remove_all_canvas_events
    local_course.delete
  end
end

# check for structual changes in canvas courses
# semester - semester string "YY[h|v]" e.g "18v"
def check_canvas_structure_change(semester)
  AppLog.log.info("Starting check for change in Canvas course structure")
  # fetch all active courses from TP
  tp_courses = HTTParty.get(TpBaseUrl + "/course?id=186&sem=#{semester}&times=1")
  sis_semester = make_sis_semester(semester)

  tp_courses["data"].each do |tp_course|
    begin
      canvas_courses = fetch_and_clean_canvas_courses(tp_course['id'], semester)

      canvas_courses_ids = canvas_courses.collect{|c| c["sis_course_id"]}

      local_courses = CanvasCourse.where(Sequel.lit("sis_course_id like '%#{tp_course['id']}\\_%\\_#{sis_semester}%'")).collect{|c| c.sis_course_id}

      diff =  local_courses - canvas_courses_ids | canvas_courses_ids - local_courses

      unless (local_courses - canvas_courses_ids).empty?
        remove_local_courses_missing_from_canvas(local_courses - canvas_courses_ids)
        AppLog.log.error("Local course removed from canvas. courseid:#{tp_course['id']} semester: #{semester}")
        Raven.capture_message("Local course removed from canvas. courseid:#{tp_course['id']} semester: #{semester}")
      end

      unless diff.empty?
        AppLog.log.info("Course changed in Canvas need to update. courseid: #{tp_course['id']} semester: #{semester} terminnr: #{tp_course['terminnr']}")
        update_one_tp_course_in_canvas(tp_course['id'], semester, tp_course['terminnr'])
      end
    rescue Exception => e
      Raven.capture_exception(e)
      AppLog.log.error(e)
    end
  end

end

# update entire semester in Canvas
# semester - semester string "YY[h|v]" e.g "18v"
def full_sync(semester)
  AppLog.log.info("Starting full update for semester: #{semester}")
  # fetch all active courses from TP
  tp_courses = HTTParty.get(TpBaseUrl + "/course?id=186&sem=#{semester}&times=1")
  threads = []
  tp_courses["data"].each do |tp_course|
    sleep 1 while threads.length > 4
    threads.each do |t|
      AppLog.log.debug("Active thread - #{t[:name]} - #{t.object_id}")
    end  
    threads << Thread.new(tp_course["id"], semester, tp_course["terminnr"]) do |t_id, t_semesterid, t_terminnr|
      begin
        Thread.current[:name] = "#{t_id}-#{t_terminnr}-#{t_semesterid}"
        update_one_tp_course_in_canvas(t_id, t_semesterid, t_terminnr)
      rescue Exception => e
        Raven.capture_exception(e)
        AppLog.log.error(e)
      ensure
        threads.delete(Thread.current)
      end
    end
    sleep 1
  end

end

def remove_one_tp_course_from_canvas(courseid, semesterid, termnr)

  sis_semester = make_sis_semester(semesterid)

  CanvasCourse.where(Sequel.lit("sis_course_id like '%#{courseid}\\_%\\_#{sis_semester}%'")).each do |course|
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

# fetch canvas courses from ws
# remove wrong semester and wrong courseid
# courseid - String e.g "INF-1100"
# semesterid - String e.g "18v"
def fetch_and_clean_canvas_courses(courseid, semesterid)
  # fetch Canvas courses
  canvas_courses_res = HTTParty.get(URI.escape(CanvasBaseUrl + "/accounts/1/courses?search_term=#{courseid}&per_page=100"), headers: Headers)
  next_url = canvas_courses_res.headers["link"].split(",").select{|l| l.include?('rel="next"')}
  canvas_courses = canvas_courses_res.parsed_response
  #fetch paginated
  while next_url.empty? == false
    next_page = HTTParty.get(URI.escape(next_url.first.split(";").first[1..-2]), headers: Headers)
    canvas_courses += next_page.parsed_response
    next_url = next_page.headers["link"].split(",").select{|l| l.include?('rel="next"')}
  end

  # remove all with wrong semester and wrong courseid
  sis_semester = make_sis_semester(semesterid)
  canvas_courses.keep_if{|c| c["sis_course_id"] and c["sis_course_id"].include?("_#{courseid}_") and c["sis_course_id"].upcase.include?(sis_semester.upcase)}

  return canvas_courses

end

# update one course in Canvas
# courseid - String e.g "INF-1100"
# semesterid - String e.g "18v"
# termnr - Int/String
def update_one_tp_course_in_canvas(courseid, semesterid, termnr)

  # fetch TP timetable
  timetable = HTTParty.get(URI.escape(TpBaseUrl + "/1.4/?id=#{courseid}&sem=#{semesterid}&termnr=#{termnr}"))

  # fetch Canvas courses
  canvas_courses = fetch_and_clean_canvas_courses(courseid, semesterid)
  return if canvas_courses.empty?

  #only one course in Canvas
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

    add_timetable_to_canvas(ua, group_timetable, timetable['courseid'])

    plenary_timetable = timetable["data"]["plenary"]

    add_timetable_to_one_canvas_course(ue.first, plenary_timetable, timetable['courseid']) if ue.first


  end


end


# Subscribe to message queue and update when courses change
def queue_subscriber
  # Connect to the RabbitMQ server
  connection = Bunny.new(hostname: MqHost, user: ENV["MQ_USER"], pass: ENV["MQ_PASS"])
  connection.start

  # Create our channel and config it
  channel = connection.create_channel
  channel.prefetch(1)

  # Get exchange
  exchange = channel.fanout(MqExchange, durable: true)

  # Get our queue
  queue = channel.queue(MqQueue, durable:true, exclusive:false)
  queue.bind(exchange)


  # subscribe to queue
  queue.subscribe(block: true, manual_ack: true) do |delivery_info, properties, body|
      AppLog.log.debug(" [x] Received #{body}")
      $threads.each do |t|
        AppLog.log.debug("Active thread - #{t[:name]} - #{t.object_id}")
      end
      channel.ack(delivery_info.delivery_tag)
      course = JSON.parse(body)
      if ["BOOKING", "EKSAMEN"].include?(course["id"]) == false # ignore BOOKING and EKSAMEN
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


        # add new thread for course-semester-termnr combination
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
        sleep 1 # sleep between each thread spawn to ensure name set in thread.
      end


  end

end

opts = Trollop::options do
  banner "Command-Line utility to sync timetables from TP to Canvas.\nUsage: ruby #{File.basename(__FILE__)} [options]"
  opt :semester, "Add full semester <s>=YY[h/v] e.g '--semester 18v'", short: "-s", long: "--semester", type: :string
  opt :course, "Add course '--course <courseid> <semester> <termnr>' e.g --course MED-3601 18h 1", short: "-c", long: "--course", type: :strings
  opt :remove_course, "Remove course from Canvas '--course <courseid> <semester> <termnr>'  e.g --remove-course MED-3601 18h 1", short: "-r", long: "--remove-course", type: :strings
  opt :mq, "Monitor message queue for updates", short: "-m", long: "--message-queue"
  opt :canvas_change, "Check for Canvas change <s>=YY[h/v] e.g '--canvas-diff 18v'", short: "-d", long: "--canvas-diff", type: :string
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
elsif opts[:canvas_change_given]
  check_canvas_structure_change(opts[:canvas_change])
else

end
