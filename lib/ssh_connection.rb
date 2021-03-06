require 'rye'
class Rye::Box
  def run_command_with_timeout(*args, &blk)
    Timeout::timeout(15) { run_command_without_timeout(*args, &blk) }
  end
  alias_method :run_command_without_timeout, :run_command
  alias_method :run_command, :run_command_with_timeout
end

class AlertMachine
  class SshConnection

    def initialize
      @connections = {}
    end

    def box(host)
      @connections[host] = nil if (@connections[host] || [0])[0] < 1.hour.ago.to_i
      @connections[host] ||= [Time.now.to_i,
        Rye::Box.new(host, AlertMachine.ssh_config.merge(:safe => false))]
      @connections[host][1]
    end

    def set(hosts)
      set = Rye::Set.new(hosts.join(","), :parallel => true)
      hosts.each { |m| set.add_box(box(m)) }
      set
    end

    def run(hosts, cmd)
      puts "[#{Time.now}] executing on #{hosts}: #{cmd}"
      res = set(hosts).execute(cmd).group_by {|ry| ry.box.hostname }.
        sort_by {|name, op| hosts.index(name) }
      res.each { |machine, op|
        puts "[#{Time.now}] [#{machine}]\n#{op.join("\n")}\n"
      }
    rescue Exception => e
      puts "[#{Time.now}] Executing cmd on machines raised exception."
      puts "#{hosts} => #{cmd}"
      puts "#{e}"
      puts "#{e.backtrace.join("\n")}"
    end
    
  end
end