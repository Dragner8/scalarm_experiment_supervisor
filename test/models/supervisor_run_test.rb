require 'test_helper'
require 'mocha/test_unit'
require 'fileutils'
require 'scalarm/service_core/test_utils/db_helper'

class SupervisorRunTest < ActiveSupport::TestCase
  include Scalarm::ServiceCore::TestUtils::DbHelper

  PID = '123'
  MESSAGE = "Supervisor script is not running\nLast 100 lines of supervisor output:\n"
  ADDRESS = 'address'
  REASON = 'reason'
  EXPERIMENT_ID = 'some_id'
  USER = 'user'
  PASSWORD = 'password'

  def setup
    super
    @supervisor_script = SupervisorRun.new({})
    @experiment = stub_everything 'experiment'
  end

  test "check methods return true when script is running" do
    @supervisor_script.pid = PID
    @supervisor_script.is_running = true

    @supervisor_script.expects(:`).with("ps #{PID}")
    system('false')
    $?.expects(:success?).returns(true)
    assert @supervisor_script.check, 'Check method should return true'
    assert @supervisor_script.is_running, 'is_running flag should not be modified'
  end

  test "check methods return false when script is not running and set is_running to false" do
    @supervisor_script.pid = PID
    @supervisor_script.is_running = true

    @supervisor_script.expects(:`).with("ps #{PID}")
    system('false')
    $?.expects(:success?).returns(false)
    assert_not @supervisor_script.check, 'Check method should return false'
    assert @supervisor_script.is_running, 'is_running flag should not be modified'
  end

  test "monitoring loop proper behavior when script is running" do
    @supervisor_script.is_running = true
    # mock
    @supervisor_script.expects(:check).returns(true)
    @supervisor_script.expects(:notify_error).never

    # test
    @supervisor_script.monitoring_loop
    assert @supervisor_script.is_running, 'is_running flag should be true'
  end

  test "monitoring loop proper behavior when script is not running and experiment is completed" do
    @supervisor_script.is_running = true
    # mock
    @supervisor_script.expects(:check).returns(false)
    @supervisor_script.expects(:notify_error).with(MESSAGE)
    @supervisor_script.expects(:read_log).returns('')
    @supervisor_script.stubs(:experiment).returns(@experiment)
    @experiment.stubs(:completed).returns(false)
    @supervisor_script.expects(:move_log)

    # test
    @supervisor_script.monitoring_loop
    assert_not @supervisor_script.is_running, 'is_running flag should be false'
  end

  test 'do not notify error when script is not running and experiment is completed' do
    @supervisor_script.is_running = true
    # mock
    @supervisor_script.expects(:check).returns(false)
    @supervisor_script.expects(:notify_error).never
    @supervisor_script.stubs(:experiment).returns(@experiment)
    @experiment.stubs(:completed).returns(true)
    @supervisor_script.expects(:move_log)

    # test
    @supervisor_script.monitoring_loop
    assert_not @supervisor_script.is_running, 'is_running flag should be false'
  end

  test "monitoring loop should raise exception when script is not running" do
    e = assert_raises RuntimeError do
      @supervisor_script.monitoring_loop
    end
    assert_equal e.to_s, 'Tried to check supervisor script executior state, but it is not running'
  end

  test "proper behavior of notify error" do
    @supervisor_script.experiment_id = EXPERIMENT_ID
    @supervisor_script.experiment_manager_credentials = {'user' => USER, 'password' => PASSWORD}
    # mocks
    information_service = mock 'InformationService'
    information_service.expects(:sample_public_url).with('experiment_managers').returns(ADDRESS)
    InformationService.expects(:instance).returns(information_service)

    RestClient::Request.expects(:execute).with(
        method: :post,
        url: "https://#{ADDRESS}/experiments/#{EXPERIMENT_ID}/mark_as_complete.json",
        payload: {status: 'error', reason: REASON},
        user: USER,
        password: PASSWORD,
        verify_ssl: false
    ).returns({status: 'ok'}.to_json)

    # test
    @supervisor_script.notify_error REASON
  end

  test "proper behavior of notify error when there is no available experiment manager" do
    @supervisor_script.experiment_id = EXPERIMENT_ID
    @supervisor_script.experiment_manager_credentials = {'user' => USER, 'password' => PASSWORD}
    # mocks
    information_service = mock 'InformationService'
    information_service.expects(:sample_public_url).with('experiment_managers').returns(nil)
    InformationService.expects(:instance).returns(information_service)

    RestClient::Request.expects(:execute).never

    # test
    @supervisor_script.notify_error REASON
  end

  FILE_PATH = '/tmp/test.txt'

  test "proper behavior od read_log method when lines number is greater than 100" do
    @supervisor_script.expects(:log_path).returns(FILE_PATH)

    File.open(FILE_PATH, 'w+') do |file|
      (1..101).each {|x| file.write("#{x}\n")}
    end
    assert_equal @supervisor_script.read_log, "#{(2..101).to_a.join("\n")}\n"
    File.delete(FILE_PATH)
  end

  test "proper behavior od read_log method when lines number is lower than 100" do
    @supervisor_script.expects(:log_path).returns(FILE_PATH)

    File.open(FILE_PATH, 'w+') do |file|
      (1..99).each {|x| file.write("#{x}\n")}
    end
    assert_equal @supervisor_script.read_log, "#{(1..99).to_a.join("\n")}\n"
    File.delete(FILE_PATH)
  end

  test "proper behavior od read_log method when lines number is equal 100" do
    @supervisor_script.expects(:log_path).returns(FILE_PATH)

    File.open(FILE_PATH, 'w+') do |file|
      (1..100).each {|x| file.write("#{x}\n")}
    end
    assert_equal @supervisor_script.read_log, "#{(1..100).to_a.join("\n")}\n"
    File.delete(FILE_PATH)
  end

  test "proper behavior od read_log method on file reading error" do
    @supervisor_script.expects(:log_path).times(3).returns(FILE_PATH)
    IO.expects(:readlines).with(FILE_PATH).throws(StandardError)
    assert_equal @supervisor_script.read_log, "Unable to load log file: #{FILE_PATH}"
  end

  test "proper behaviour of stop method with stubborn process" do
    @supervisor_script.pid = PID
    @supervisor_script.is_running = true
    @supervisor_script.expects(:check).returns(true).twice
    Process.expects(:kill).with('TERM', PID)
    Process.expects(:kill).with('KILL', PID)

    @supervisor_script.stop

    assert_equal false, @supervisor_script.is_running
  end

  test "proper behaviour of stop method with cooperating process" do
    @supervisor_script.pid = PID
    @supervisor_script.is_running = true
    @supervisor_script.expects(:check).returns(true).then.returns(false).twice
    Process.expects(:kill).with('TERM', PID)

    @supervisor_script.stop

    assert_equal false, @supervisor_script.is_running
  end


  test "proper behaviour of destroy method when script is not running" do
    @supervisor_script.expects(:check).returns(false)
    @supervisor_script.save

    assert_difference 'SupervisorRun.count', -1 do
      @supervisor_script.destroy
    end
  end

  test "proper behaviour of destroy method when script is running" do
    @supervisor_script.expects(:check).returns(true)
    @supervisor_script.expects(:stop)
    @supervisor_script.save

    assert_difference 'SupervisorRun.count', -1 do
      @supervisor_script.destroy
    end
  end

  STATE_ALLOWED_KEYS = [:experiment_id, :supervisor_id, :pid, :is_running, :supervisor_run_id]

  test "state returns all and only allowed keys" do
    @supervisor_script.experiment_id = 'val'
    @supervisor_script.supervisor_id = 'val'
    @supervisor_script.pid = 'val'
    @supervisor_script.is_running = 'val'

    state = @supervisor_script.state
    assert_nothing_raised do
      state.assert_valid_keys(STATE_ALLOWED_KEYS)
    end
    STATE_ALLOWED_KEYS.each {|key| assert state.has_key?(key), "State should contains key #{key}"}
  end

  ARCHIVE_LOG_PATH='/tmp/'

  test 'move_log should move log when log file exists and config entry is present' do
    # given
    original_log_file_path = AbstractSupervisorExecutor.log_path EXPERIMENT_ID
    new_log_file_path = ARCHIVE_LOG_PATH + AbstractSupervisorExecutor.log_file_name(EXPERIMENT_ID)
    FileUtils.touch(original_log_file_path)
    @supervisor_script.expects(:experiment_id).returns(EXPERIMENT_ID)
    secrets = mock do
      expects(:include?).with(:log_archive_path).returns(true)
      expects(:log_archive_path).returns(ARCHIVE_LOG_PATH).twice
    end
    Rails.application.expects(:secrets).returns(secrets).times(3)
    # when
    @supervisor_script.send(:move_log) # hack to call private method
    # then
    assert_not File.exists?(original_log_file_path), 'File should be moved to proper location'
    assert File.exists?(new_log_file_path), 'File should be moved to proper location'
    # cleanup
    remove_file_if_exists original_log_file_path
    remove_file_if_exists new_log_file_path
  end

  test 'move_log should not move log when log file not exists' do
    # given
    original_log_file_path = AbstractSupervisorExecutor.log_path EXPERIMENT_ID
    remove_file_if_exists original_log_file_path
    new_log_file_path = ARCHIVE_LOG_PATH + AbstractSupervisorExecutor.log_file_name(EXPERIMENT_ID)
    @supervisor_script.expects(:experiment_id).returns(EXPERIMENT_ID)
    secrets = mock do
      expects(:include?).with(:log_archive_path).returns(true)
    end
    Rails.application.expects(:secrets).returns(secrets)
    # when
    @supervisor_script.send(:move_log) # hack to call private method
    # then
    assert_not File.exists?(new_log_file_path), 'Log file should not exist'
    # cleanup
    remove_file_if_exists new_log_file_path
  end

  test 'move_log should not move log when config entry is not present' do
    # given
    original_log_file_path = AbstractSupervisorExecutor.log_path EXPERIMENT_ID
    new_log_file_path = ARCHIVE_LOG_PATH + AbstractSupervisorExecutor.log_file_name(EXPERIMENT_ID)
    FileUtils.touch(original_log_file_path)
    @supervisor_script.expects(:experiment_id).returns(EXPERIMENT_ID)
    secrets = mock do
      expects(:include?).with(:log_archive_path).returns(false)
    end
    Rails.application.expects(:secrets).returns(secrets)
    # when
    @supervisor_script.send(:move_log) # hack to call private method
    # then
    assert File.exists?(original_log_file_path), 'File should not be moved'
    assert_not File.exists?(new_log_file_path), 'File should not be moved'
    # cleanup
    remove_file_if_exists original_log_file_path
    remove_file_if_exists new_log_file_path
  end

end
