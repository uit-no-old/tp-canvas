Sequel.migration do
  change do
    create_table(:canvas_courses) do
      primary_key :id
      Integer :canvas_id, null: false
      String :name
      String :course_code
      String :sis_course_id
    end
  end
end
