require 'mysql2'

dest_dir = ARGV[0]
Dir.mkdir(dest_dir)

db_client = Mysql2::Client.new(
  host: ENV.fetch('ISUBATA_DB_HOST') { 'localhost' },
  port: ENV.fetch('ISUBATA_DB_PORT') { '3306' },
  username: ENV.fetch('ISUBATA_DB_USER') { 'root' },
  password: ENV.fetch('ISUBATA_DB_PASSWORD') { '' },
  database: 'isubata',
  encoding: 'utf8mb4'
)
db_client.query('SET SESSION sql_mode=\'TRADITIONAL,NO_AUTO_VALUE_ON_ZERO,ONLY_FULL_GROUP_BY\'')

db_client.query('SELECT id, name, data FROM image').each do |row|
  id = row['id']
  filename = File.join(dest_dir, row['name'])
  File.open(filename, 'w') do |f|
    f.write row['data']
  end
  puts "#{id}: #{filename}: done."
end
