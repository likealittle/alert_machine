# A single watch and it's life cycle.
class AlertMachine
  class RunTask
    def initialize(opts, block, caller)
      @opts, @block, @caller = opts, block, caller
      @errors = []
      @alert_state = false
    end

    def schedule
      @timer = EM::PeriodicTimer.new(interval) do
        with_task do
          start = Time.now
          begin
            # The main call to the user-defined watcher function.
            @block.call(*@opts[:args])

            assert(Time.now - start < interval / 5.0,
              "Task ran for too long. Invoked every #{
              interval}s. Ran for #{Time.now - start}s.", @caller) unless
              AlertMachine.dont_check_long_processes

            # Things finished successfully.
            @timer.interval = interval if !@errors.empty?
            @errors = []

            alert_state(false)

          rescue Exception => e
            puts "Exception: #{e.to_s}"
            puts "#{e.backtrace.join("\n")}"

            af = e.is_a?(AssertionFailure) ? e : AssertionFailure.new(e.to_s, e.backtrace)

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
        mail unless @last_mailed && @last_mailed > Time.now - 60*10
        @last_mailed = Time.now
      end
      @alert_state = firing
    end

    def mail
      last = @errors[-1]
      ActionMailer::Base.mail(
        :from => opts(:from),
        :to => opts(:to),
        :subject => "AlertMachine Failed: #{last.msg || last.parsed_caller.file_line}"
      ) do |format|
        format.text {
          render :text =>
            @errors.collect {|e| e.log}.join("\n=============\n")
        }
      end.deliver
    end

    def opts(key, defaults = nil)
      @opts[key] || config[key.to_s] || defaults || block_given? && yield
    end

    def interval; opts(:interval, 5 * 60).to_f; end

    def interval_error; opts(:interval_error) { interval / 5.0 }.to_f; end

    def retries; opts(:retries, 1).to_i; end

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
          "#{Caller.new(caller).log}"
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