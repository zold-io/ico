# Copyright (c) 2018-2019 Zerocracy, Inc.
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the 'Software'), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED 'AS IS', WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

STDOUT.sync = true

require 'rubygems'
require 'rake'
require 'yaml'
require 'shellwords'
require 'rdoc'
require 'rake/clean'
require 'English'

ENV['RACK_ENV'] = 'test'

task default: %i[clean test rubocop xcop eslint copyright]

require 'rake/testtask'
desc 'Run all unit tests'
Rake::TestTask.new(test: :liquibase) do |test|
  Rake::Cleaner.cleanup_files(['coverage'])
  ENV['TEST_QUIET_LOG'] = 'true' if ARGV.include?('--quiet')
  test.libs << 'lib' << 'test'
  test.pattern = 'test/**/test_*.rb'
  test.verbose = true
  test.warning = false
end

require 'rubocop/rake_task'
desc 'Run RuboCop on all directories'
RuboCop::RakeTask.new(:rubocop) do |task|
  task.fail_on_error = true
  task.requires << 'rubocop-rspec'
end

require 'eslintrb/eslinttask'
Eslintrb::EslintTask.new :eslint do |t|
  t.pattern = 'assets/js/**/*.js'
  t.options = :defaults
end

require 'xcop/rake_task'
desc 'Validate all XML/XSL/XSD/HTML files for formatting'
Xcop::RakeTask.new :xcop do |task|
  task.license = 'LICENSE.txt'
  task.includes = ['**/*.xml', '**/*.xsl', '**/*.xsd', '**/*.html']
  task.excludes = ['target/**/*', 'coverage/**/*']
end

desc 'Start PostgreSQL Local server'
task :pgsql do
  FileUtils.mkdir_p('target')
  dir = File.expand_path(File.join(Dir.pwd, 'target/pgsql'))
  FileUtils.rm_rf(dir)
  File.write('target/pwfile', 'test')
  out = "2>&1 #{ARGV.include?('--quiet') ? '>/dev/null' : ''}"
  system("initdb --auth=trust -D #{dir} --username=test --pwfile=target/pwfile #{out}")
  raise unless $CHILD_STATUS.exitstatus.zero?
  port = `python -c 'import socket; s=socket.socket(); s.bind(("", 0)); print(s.getsockname()[1]); s.close()'`.to_i
  pid = Process.spawn('postgres', '-k', dir, '-D', dir, "--port=#{port}")
  at_exit do
    `kill -TERM #{pid}`
    puts "PostgreSQL killed in PID #{pid}"
  end
  sleep 1
  attempt = 0
  begin
    system("createdb -h localhost -p #{port} --username=test test #{out}")
    raise unless $CHILD_STATUS.exitstatus.zero?
  rescue StandardError => e
    puts e.message
    sleep(5)
    attempt += 1
    raise if attempt > 10
    retry
  end
  File.write('target/pgsql.port', port.to_s)
  File.write(
    'target/config.yml',
    [
      'pgsql:',
      '  host: localhost',
      "  port: #{port}",
      '  dbname: test',
      '  user: test',
      '  password: test',
      "  url: jdbc:postgresql://localhost:#{port}/test?user=test&password=test"
    ].join("\n")
  )
  puts "PostgreSQL is running in PID #{pid}"
end

desc 'Update the database via Liquibase'
task liquibase: :pgsql do
  yml = YAML.safe_load(File.open(File.exist?('config.yml') ? 'config.yml' : 'target/config.yml'))
  system(
    [
      'mvn -f liquibase verify',
      "-Durl=#{Shellwords.escape(yml['pgsql']['url'])}",
      '--errors',
      "-Dliquibase.logging=#{ARGV.include?('--quiet') ? 'severe' : 'info'}",
      ARGV.include?('--quiet') ? '--quiet' : '',
      '2>&1'
    ].join(' ')
  )
  raise unless $CHILD_STATUS.exitstatus.zero?
end

desc 'Sleep endlessly after the start of DynamoDB Local server'
task :sleep do
  loop do
    sleep(5)
    puts 'Still alive...'
  end
end

task run: :liquibase do
  puts 'Starting the app...'
  system('rerun -b "RACK_ENV=test ruby wts.rb"')
end

task :copyright do
  sh "grep -q -r '#{Date.today.strftime('%Y')}' \
    --include '*.rb' \
    --include '*.txt' \
    --include 'Rakefile' \
    ."
end
