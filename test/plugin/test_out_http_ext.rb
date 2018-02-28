# -*- coding: utf-8 -*-
require 'uri'
require 'yajl'
require 'fluent/test/http_output_test'
require 'fluent/plugin/out_http_ext'


TEST_LISTEN_PORT = 5126


class HTTPOutputTestBase < Test::Unit::TestCase
  # setup / teardown for servers
  def setup
    Fluent::Test.setup
    @posts = []
    @puts = []
    @prohibited = 0
    @requests = 0
    @auth = false
    @status = 200
    @dummy_server_thread = Thread.new do
      srv = if ENV['VERBOSE']
              WEBrick::HTTPServer.new({:BindAddress => '127.0.0.1', :Port => TEST_LISTEN_PORT})
            else
              logger = WEBrick::Log.new('/dev/null', WEBrick::BasicLog::DEBUG)
              WEBrick::HTTPServer.new({:BindAddress => '127.0.0.1', :Port => TEST_LISTEN_PORT, :Logger => logger, :AccessLog => []})
            end
      begin
        allowed_methods = %w(POST PUT)
        srv.mount_proc('/api/') { |req,res|
          @requests += 1
          unless allowed_methods.include? req.request_method
            res.status = 405
            res.body = 'request method mismatch'
            next
          end
          if @auth and req.header['authorization'][0] == 'Basic YWxpY2U6c2VjcmV0IQ==' # pattern of user='alice' passwd='secret!'
            # ok, authorized
          elsif @auth
            res.status = 403
            @prohibited += 1
            next
          else
            # ok, authorization not required
          end

          record = {:auth => nil}
          if req.content_type == 'application/json'
            record[:json] = Yajl.load(req.body)
          else
            record[:form] = Hash[*(req.body.split('&').map{|kv|kv.split('=')}.flatten)]
          end

          instance_variable_get("@#{req.request_method.downcase}s").push(record)

          res.status = @status
        }
        srv.mount_proc('/') { |req,res|
          res.status = 200
          res.body = 'running'
        }
        srv.mount_proc('/slow_5') { |req,res|
          sleep 5
          res.status = 200
          res.body = 'slow_5'
        }
        srv.mount_proc('/slow_10') { |req,res|
          sleep 10
          res.status = 200
          res.body = 'slow_10'
        }
        srv.mount_proc('/status_code') { |req,res|
          r = Yajl.load(req.body)
          code = r["code"]
          res.status = code.to_s
          res.body = ''
        }

        srv.start
      ensure
        srv.shutdown
      end
    end

    # to wait completion of dummy server.start()
    require 'thread'
    cv = ConditionVariable.new
    watcher = Thread.new {
      connected = false
      while not connected
        begin
          get_content('localhost', TEST_LISTEN_PORT, '/')
          connected = true
        rescue Errno::ECONNREFUSED
          sleep 0.1
        rescue StandardError => e
          p e
          sleep 0.1
        end
      end
      cv.signal
    }
    mutex = Mutex.new
    mutex.synchronize {
      cv.wait(mutex)
    }
  end

  def test_dummy_server
    host = '127.0.0.1'
    port = TEST_LISTEN_PORT
    client = Net::HTTP.start(host, port)

    assert_equal '200', client.request_get('/').code
    assert_equal '200', client.request_post('/api/service/metrics/hoge', 'number=1&mode=gauge').code

    assert_equal 1, @posts.size

    assert_equal '1', @posts[0][:form]['number']
    assert_equal 'gauge', @posts[0][:form]['mode']
    assert_nil @posts[0][:auth]

    @auth = true

    assert_equal '403', client.request_post('/api/service/metrics/pos', 'number=30&mode=gauge').code

    req_with_auth = lambda do |number, mode, user, pass|
      url = URI.parse("http://#{host}:#{port}/api/service/metrics/pos")
      req = Net::HTTP::Post.new(url.path)
      req.basic_auth user, pass
      req.set_form_data({'number'=>number, 'mode'=>mode})
      req
    end

    assert_equal '403', client.request(req_with_auth.call(500, 'count', 'alice', 'wrong password!')).code

    assert_equal '403', client.request(req_with_auth.call(500, 'count', 'alice', 'wrong password!')).code

    assert_equal 1, @posts.size

    assert_equal '200', client.request(req_with_auth.call(500, 'count', 'alice', 'secret!')).code

    assert_equal 2, @posts.size

  end

  def teardown
    @dummy_server_thread.kill
    @dummy_server_thread.join
  end
end

class HTTPOutputTest < HTTPOutputTestBase
  CONFIG = %[
    endpoint_url http://127.0.0.1:#{TEST_LISTEN_PORT}/api/
  ]

  CONFIG_JSON = %[
    endpoint_url http://127.0.0.1:#{TEST_LISTEN_PORT}/api/
    serializer json
  ]

  CONFIG_PUT = %[
    endpoint_url http://127.0.0.1:#{TEST_LISTEN_PORT}/api/
    http_method put
  ]

  CONFIG_HTTP_ERROR = %[
    endpoint_url https://127.0.0.1:#{TEST_LISTEN_PORT + 1}/api/
  ]

  CONFIG_HTTP_ERROR_SUPPRESSED = %[
    endpoint_url https://127.0.0.1:#{TEST_LISTEN_PORT + 1}/api/
    raise_on_error false
  ]

  CONFIG_RAISE_ON_HTTP_FAILURE = %[
    endpoint_url http://127.0.0.1:#{TEST_LISTEN_PORT}/api/
    raise_on_http_failure true
  ]

  RATE_LIMIT_MSEC = 1200

  CONFIG_RATE_LIMIT = %[
    endpoint_url http://127.0.0.1:#{TEST_LISTEN_PORT}/api/
    rate_limit_msec #{RATE_LIMIT_MSEC}
  ]

  CONFIG_NOT_READ_TIMEOUT = %[
    endpoint_url http://127.0.0.1:#{TEST_LISTEN_PORT}/slow_5/
    read_timeout 7
  ]
  CONFIG_READ_TIMEOUT = %[
    endpoint_url http://127.0.0.1:#{TEST_LISTEN_PORT}/slow_10/
    read_timeout 7
  ]
  CONFIG_IGNORE_NONE = %[
    endpoint_url http://127.0.0.1:#{TEST_LISTEN_PORT}/status_code/
    serializer json
    raise_on_http_failure true
  ]
  CONFIG_IGNORE_409 = %[
    endpoint_url http://127.0.0.1:#{TEST_LISTEN_PORT}/status_code/
    serializer json
    raise_on_http_failure true
    ignore_http_status_code 409
  ]
  CONFIG_IGNORE_4XX = %[
    endpoint_url http://127.0.0.1:#{TEST_LISTEN_PORT}/status_code/
    serializer json
    raise_on_http_failure true
    ignore_http_status_code 400..499
  ]
  CONFIG_IGNORE_4XX_5XX = %[
    endpoint_url http://127.0.0.1:#{TEST_LISTEN_PORT}/status_code/
    serializer json
    raise_on_http_failure true
    ignore_http_status_code 400..599
  ]

  CONFIG_CUSTOM_FORMATTER = %[
    endpoint_url http://127.0.0.1:#{TEST_LISTEN_PORT}/api/
    serializer json
    format test_formatter
  ]

  def create_driver(conf=CONFIG, tag='test.metrics')
    Fluent::Test::OutputTestDriver.new(Fluent::HTTPOutput, tag).configure(conf)
  end

  def test_configure
    d = create_driver
    assert_equal "http://127.0.0.1:#{TEST_LISTEN_PORT}/api/", d.instance.endpoint_url
    assert_equal :form, d.instance.serializer

    d = create_driver CONFIG_JSON
    assert_equal "http://127.0.0.1:#{TEST_LISTEN_PORT}/api/", d.instance.endpoint_url
    assert_equal :json, d.instance.serializer
  end

  def test_emit_form
    d = create_driver
    d.emit({ 'field1' => 50, 'field2' => 20, 'field3' => 10, 'otherfield' => 1, 'binary' => "\xe3\x81\x82".force_encoding("ascii-8bit") })
    d.run

    assert_equal 1, @posts.size
    record = @posts[0]

    assert_equal '50', record[:form]['field1']
    assert_equal '20', record[:form]['field2']
    assert_equal '10', record[:form]['field3']
    assert_equal '1', record[:form]['otherfield']
    assert_nil record[:auth]

    d.emit({ 'field1' => 50, 'field2' => 20, 'field3' => 10, 'otherfield' => 1 })
    d.run

    assert_equal 2, @posts.size
  end

  def test_emit_form_put
    d = create_driver CONFIG_PUT
    d.emit({ 'field1' => 50 })
    d.run

    assert_equal 0, @posts.size
    assert_equal 1, @puts.size
    record = @puts[0]

    assert_equal '50', record[:form]['field1']
    assert_nil record[:auth]

    d.emit({ 'field1' => 50 })
    d.run

    assert_equal 0, @posts.size
    assert_equal 2, @puts.size
  end

  def test_emit_json_object
    binary_string = "あ"
    d = create_driver CONFIG_JSON
    d.emit({ 'field1' => 50, 'field2' => 20, 'field3' => 10, 'otherfield' => 1, 'binary' => binary_string })
    d.run

    assert_equal 1, @posts.size
    record = @posts[0]

    assert_equal 50, record[:json]['field1']
    assert_equal 20, record[:json]['field2']
    assert_equal 10, record[:json]['field3']
    assert_equal 1, record[:json]['otherfield']
    assert_equal binary_string, record[:json]['binary']
    assert_nil record[:auth]
  end

  def test_emit_json_array
    binary_string = "あ"
    d = create_driver CONFIG_JSON
    d.emit([ 5, binary_string, 30 ])
    d.run

    assert_equal 1, @posts.size
    record = @posts[0]

    assert_equal 5, record[:json][0]
    assert_equal binary_string, record[:json][1]
    assert_equal 30, record[:json][2]
    assert_nil record[:auth]
  end

  def test_http_error_is_raised
    d = create_driver CONFIG_HTTP_ERROR
    assert_raise Errno::ECONNREFUSED do
      d.emit({ 'field1' => 50 })
    end
  end

  def test_http_error_is_suppressed_with_raise_on_error_false
    d = create_driver CONFIG_HTTP_ERROR_SUPPRESSED
    d.emit({ 'field1' => 50 })
    d.run
    # drive asserts the next output chain is called;
    # so no exception means our plugin handled the error

    assert_equal 0, @requests
  end

  def test_http_failure_is_not_raised_on_http_failure_true_and_status_201
    @status = 201

    d = create_driver CONFIG_RAISE_ON_HTTP_FAILURE
    assert_nothing_raised do
      d.emit({ 'field1' => 50 })
    end

    @status = 200
  end

  def test_http_failure_is_raised_on_http_failure_true
    @status = 500

    d = create_driver CONFIG_RAISE_ON_HTTP_FAILURE
    assert_raise RuntimeError do
      d.emit({ 'field1' => 50 })
    end

    @status = 200
  end

  def test_rate_limiting
    d = create_driver CONFIG_RATE_LIMIT
    record = { :k => 1 }

    last_emit = _current_msec
    d.emit(record)
    d.run

    assert_equal 1, @posts.size

    d.emit({})
    d.run
    assert last_emit + RATE_LIMIT_MSEC > _current_msec, "Still under rate limiting interval"
    assert_equal 1, @posts.size

    wait_msec = 500
    sleep (last_emit + RATE_LIMIT_MSEC - _current_msec + wait_msec) * 0.001

    assert last_emit + RATE_LIMIT_MSEC < _current_msec, "No longer under rate limiting interval"
    d.emit(record)
    d.run
    assert_equal 2, @posts.size
  end

  def test_read_timeout
    d = create_driver CONFIG_READ_TIMEOUT
    assert_equal 7, d.instance.read_timeout
    err = Net.const_defined?(:ReadTimeout) ? Net::ReadTimeout : Timeout::Error
    assert_raise err do
      d.emit({})
      d.run
    end
  end

  def test_not_read_timeout
    d = create_driver CONFIG_NOT_READ_TIMEOUT
    assert_equal 7, d.instance.read_timeout
    assert_nothing_raised do
      d.emit({})
      d.run
    end
  end

  def test_ignore_none
    d = create_driver CONFIG_IGNORE_NONE
    assert_equal [].to_set, d.instance.ignore_http_status_code

    assert_raise do
      d.emit({:code=> 409})
      d.run
    end

    assert_raise do
      d.emit({:code => 500})
      d.run
    end
  end

  def test_ignore_409
    d = create_driver CONFIG_IGNORE_409
    assert_equal [409].to_set, d.instance.ignore_http_status_code

    assert_nothing_raised do
      d.emit({:code => 409})
      d.run
    end
    assert_raise do
      d.emit({:code => 404})
      d.run
    end
    assert_raise do
      d.emit({:code => 500})
      d.run
    end
  end

  def test_ignore_4XX
    d = create_driver CONFIG_IGNORE_4XX
    assert_equal (400..499).to_a.to_set, d.instance.ignore_http_status_code

    assert_nothing_raised do
      d.emit({:code => 409})
      d.run
    end
    assert_nothing_raised do
      d.emit({:code => 404})
      d.run
    end
    assert_raise do
      d.emit({:code => 500})
      d.run
    end
  end

  def test_ignore_4XX_5XX
    d = create_driver CONFIG_IGNORE_4XX_5XX
    assert_equal (400..599).to_a.to_set, d.instance.ignore_http_status_code
    assert_nothing_raised do
      d.emit({:code => 409})
      d.run
    end
    assert_nothing_raised do
      d.emit({:code => 404})
      d.run
    end
    assert_nothing_raised do
      d.emit({:code => 500})
      d.run
    end
  end

  def _current_msec
    Time.now.to_f * 1000
  end

  def test_auth
    @auth = true # enable authentication of dummy server

    d = create_driver(CONFIG, 'test.metrics')
    d.emit({ 'field1' => 50, 'field2' => 20, 'field3' => 10, 'otherfield' => 1 })
    d.run # failed in background, and output warn log

    assert_equal 0, @posts.size
    assert_equal 1, @prohibited

    d = create_driver(CONFIG + %[
      authentication basic
      username alice
      password wrong_password
    ], 'test.metrics')
    d.emit({ 'field1' => 50, 'field2' => 20, 'field3' => 10, 'otherfield' => 1 })
    d.run # failed in background, and output warn log

    assert_equal 0, @posts.size
    assert_equal 2, @prohibited

    d = create_driver(CONFIG + %[
      authentication basic
      username alice
      password secret!
    ], 'test.metrics')
    d.emit({ 'field1' => 50, 'field2' => 20, 'field3' => 10, 'otherfield' => 1 })
    d.run # failed in background, and output warn log

    assert_equal 1, @posts.size
    assert_equal 2, @prohibited
  end

  def test_status_code_parser()
    assert_equal (400..409).to_a.to_set, StatusCodeParser.convert("400..409")
    assert_equal ((400..409).to_a + [300]).to_set, StatusCodeParser.convert("400..409,300")
    assert_equal ((400..409).to_a + [300]).to_set, StatusCodeParser.convert("300,400..409")
    assert_equal [404, 409].to_set, StatusCodeParser.convert("404,409")
    assert_equal [404, 409, 300, 301, 302, 303].to_set, StatusCodeParser.convert("404,409,300..303")
    assert_equal [409].to_set, StatusCodeParser.convert("409")
    assert_equal [].to_set, StatusCodeParser.convert("")
    assert_raise do
       StatusCodeParser.convert("400...499")
    end
    assert_raise do
      StatusCodeParser.convert("10..20")
    end
    assert_raise do
      StatusCodeParser.convert("4XX")
    end
    assert_raise do
      StatusCodeParser.convert("4XX..5XX")
    end
    assert_raise do
      StatusCodeParser.convert("200.0..400")
    end
    assert_raise do
      StatusCodeParser.convert("-200..400")
    end

  end

  def test_array_extend
    assert_equal [].to_set, Set.new([])
    assert_equal [1, 2].to_set, Set.new([1, 2])
  end

  def test_custom_formatter
    d = create_driver CONFIG_CUSTOM_FORMATTER
    payload = {"field" => 1}
    d.emit(payload)
    d.run

    record = @posts[0]
    assert_equal record[:json]["wrapped"], true
    assert_equal record[:json]["record"], payload
  end
end
