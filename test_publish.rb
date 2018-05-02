require 'httparty'
require 'sequel'
#require 'sqlite3'

database_url_dev = "postgres://uit-ita-sua-tp-canvas-db.postgres.database.azure.com/tp_canvas_dev?sslmode=require"
database_url_prod = "postgres://uit-ita-sua-tp-canvas-db.postgres.database.azure.com/tp_canvas_prod?sslmode=require"
DB = Sequel.connect(database_url_dev, user: ENV["DB_USER"], password: ENV["DB_PASS"])

class CanvasCourse < Sequel::Model
  one_to_many :canvas_events
end

class CanvasEvent < Sequel::Model
  many_to_one :canvas_course
end

# create event in Canvas and DB-
def add_event_to_canvas(event, db_course, courseid, canvas_course_id)
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
    puts "Event created in Canvas: #{courseid} #{event['summary']}"
    db_event = CanvasEvent.new
    db_event.canvas_id = res["id"]
    db_event.save
    db_course.add_canvas_event(db_event)
  end
end

# delete all canvas events for a course in DB
def delete_canvas_events(course)
  course.canvas_events.each do |event|
    res = HTTParty.delete(CanvasBaseUrl + "/calendar_events/#{event.canvas_id}.json", headers: Headers)
    if res.code == 200
      event.delete
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
    ua_timetable = tp_activities.select{|t| t["actid"] == actid}
    ua_timetable.each do |ua_t|
      #puts ua_t
      ua_t["eventsequences"].each do |es|
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


def fyll_sync(semester)

  tp_courses = HTTParty.get(TpBaseUrl + "/course?id=186&sem=#{semester}&times=1")
  tp_courses["data"].delete_if{|d| d["id"] < "FRA-1021"}
  tp_courses["data"].each do |tp_course|
    puts tp_course
    update_one_tp_course_in_canvas(tp_course["id"], semester, tp_course["terminnr"])
  end

end

def update_one_tp_course_in_canvas(courseid, semesterid, termnr)

  cis_semester = ""
  if semesterid[-1].upcase == "H"
    cis_semester = "#{courseid}_#{termnr}_20#{semesterid[0..1]}_HØST"
  else
    cis_semester = "#{courseid}_#{termnr}_20#{semesterid[0..1]}_VÅR"
  end

  # fetch TP timetable
  timetable = HTTParty.get(URI.escape(TpBaseUrl + "/1.4/?id=#{courseid}&sem=#{semesterid}&termnr=#{termnr}"))

  # fetch Canvas courses
  canvas_courses = HTTParty.get(URI.escape(CanvasBaseUrl + "/accounts/1/courses?search_term=#{courseid}&per_page=100"), headers: Headers)

  puts canvas_courses
  # remove all with wrong semester
  canvas_courses.keep_if{|c| c["sis_course_id"] and c["sis_course_id"].upcase.include?(cis_semester.upcase)}
  canvas_courses.each do |c|
    puts c["name"]
  end
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
    add_timetable_to_one_canvas_course(ue.first, processed_group_timetable, timetable["courseid"], false)

  end


end

# MAIN STUFF
TpBaseUrl = "https://tp.uio.no/uit/ws"
CanvasBaseUrl = "https://uit.test.instructure.com/api/v1"
Headers = {"Authorization"  => "Bearer #{ENV['CANVAS_TOKEN']}"}

fyll_sync("18h")
#update_one_tp_course_in_canvas("ØKMES", "17h", 1)
