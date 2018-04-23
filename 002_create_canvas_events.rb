Sequel.migration do
  change do
    create_table(:canvas_events) do
      primary_key :id
      foreign_key :canvas_course_id, :canvas_courses
      Integer :canvas_id, null: false
    end
  end
end
