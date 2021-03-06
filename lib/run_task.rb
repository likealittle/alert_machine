# A single watch and it's life cycle.
class AlertMachine
  class RunTask
    def initialize(opts, block, caller)
      @opts, @block, @caller = opts, block, caller
      @errors = []
      @alert_state = false
    end

    def schedule
      # Run with an interval of 1 second for the first time.
      # After the first execution the interval gets set appropriately.
      @timer = EM::PeriodicTimer.new([1, interval].min) do
        with_task do
          # Reset the interval correctly the first time.
          @first_time ||= @timer.interval = interval

          start = Time.now
          begin
            # The main call to the user-defined watcher function.
            @block.call(*@opts[:args])

            assert(Time.now - start < interval / 5.0,
              "Task ran for too long. Invoked every #{
              interval}s. Ran for #{Time.now - start}s.", @caller) unless
              dont_check_long_processes?

            # Things finished successfully.
            @timer.interval = interval if !@errors.empty?
            @errors = []

            alert_state(false)

          rescue Exception => af
            unless af.is_a?(AssertionFailure)
              puts "Task Exception: #{af.to_s}"
              puts "#{af.backtrace.join("\n")}"
              af = AssertionFailure.new(af.to_s, af.backtrace)
            end

            @timer.interval = interval_error if @errors.empty?
            @errors << af

            alert_state(true) if @errors.length > retries
          end
        end
      end
    end

    def with_task
      AlertMachine.current_task = self
      yield
    ensure
      AlertMachine.current_task = nil
    end

    def assert(condition, msg, caller)
      return if condition
      assert_failed(msg, caller)
    end

    def assert_failed(msg, caller)
      fail = AssertionFailure.new(msg, caller)
      puts fail.log
      raise fail
    end

    # Is the alert firing?
    def alert_state(firing)
      if firing != @alert_state
        @alert_state = firing
        mail unless @last_mailed && @last_mailed > Time.now - 60*10 && firing
        @last_mailed = Time.now
      end
    end

    def mail
      mail_opts = if @alert_state
        last = @errors[-1]
        @last_error_line = last.msg || last.parsed_caller.file_line
        {
          subject: "AlertMachine Failed: #{@last_error_line}",
          body: @errors.collect {|e| e.log}.join("\n=============\n")
        }
      else
        {
          subject: "AlertMachine Passed: #{@last_error_line}",
          body: "#{Caller.new(@caller).log}"
        }
      end.merge(from: opts(:from), to: opts(:to))
      eval(opts(:mailer_class, "ActionMailer::Base")).mail(mail_opts).deliver
    end

    def opts(key, defaults = nil)
      @opts[key] || config[key.to_s] || defaults || block_given? && yield
    end

    def interval; opts(:interval, 5 * 60).to_f; end

    def interval_error; opts(:interval_error) { interval / 5.0 }.to_f; end

    def retries; opts(:retries, 1).to_i; end

    def dont_check_long_processes?; opts(:dont_check_long_processes, false).to_s == "true"; end

    def config; AlertMachine.config; end

    # When an assertion fails, this exception is thrown so that
    # we can unwind the stack frame. It's also deliberately throwing
    # something that's not derived from Exception.
    class AssertionFailure < Exception
      attr_reader :msg, :caller, :time
      def initialize(msg, caller)
        @msg, @caller, @time = msg, caller, Time.now
        super(@msg)
      end

      def log
        "[#{Time.now}] #{msg ? msg + "\n" : ""}" +
          "#{Caller.new(caller).log}" + "\n" +
          "Sent from #{`hostname`.strip}:#{::Process.pid}"
      end

      def parsed_caller
        Caller.new(caller)
      end
    end


    private
    def puts(*args)
      super unless AlertMachine.test_mode?
    end
  end
end
