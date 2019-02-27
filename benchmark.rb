#!/usr/bin/env ruby
# -*- coding: utf-8 -*-
require_relative 'benchmark_helper'
require 'optparse'

BenchmarkSetting = Struct.new(:connection_string,
                              :observer_only,
                              :executor_only,
                              :client_only,
                              :plans_count,
                              :executors_count,
                              :clients_count,
                              :sub_actions_count,
                              :step_duration,
                              :ping_interval,
                              :max_iterations) do
  def set_defaults
    pg_user = ENV['USER'] == 'foreman' ? 'foreman' : 'postgres'
    self.connection_string = "postgres://#{pg_user}@/dynflow_benchmark"
    self.observer_only = false
    self.executor_only = false
    self.client_only = false
    self.plans_count = 100
    self.executors_count = 1
    self.clients_count = 1
    self.sub_actions_count = 2
    self.step_duration = 0.5
    self.ping_interval = 0.5
    self.max_iterations = 2
  end

  def action_options
    { sub_actions_count: sub_actions_count,
      step_duration: step_duration,
      ping_interval: ping_interval,
      max_iterations: max_iterations }
  end
end

settings = BenchmarkSetting.new.tap(&:set_defaults)

OptionParser.new do |opts|
  opts.banner = "Usage: benchmark.rb [options]"

  opts.on("-c", "--connection-string [CONNECTION_STRING]", "Database connection string (default #{settings.connection_string}") do |v|
    settings.connection_string = v
  end

  opts.on("-O", "--observer", "Run only observer") do
    settings.observer_only = true
  end

  opts.on("-E", "--executor", "Run only executor") do
    settings.executor_only = true
  end

  opts.on("-C", "--client", "Run only client") do
    settings.client_only = true
  end

  opts.on("-e", "--executors-count EXECUTORS_COUNT", "Number of executors to run (default #{settings.executors_count})") do |v|
    settings.executors_count = v.to_i
  end

  opts.on("-c", "--clients-count CLIENTS_COUNT", "Number of clients to run (default #{settings.clients_count})") do |v|
    settings.clients_count = v.to_i
  end

  opts.on("-p", "--plans-count PLANS_COUNT", "Number of plans to run (default #{settings.plans_count})") do |v|
    settings.plans_count = v.to_i
  end

  opts.on("-s", "--sub-actions-count SUB_ACTIONS_COUNT", "Number of sub-actions in main action (default #{settings.sub_actions_count})") do |v|
    settings.sub_actions_count = v.to_i
  end

  opts.on("-d", "--step-duration STEP_DURATION", "Duration of a single step in seconds (default #{settings.step_duration})") do |v|
    settings.step_duration = v.to_f
  end

  opts.on("-i", "--ping-interval PING_INTERVAL", "Interval between two action events in seconds (default #{settings.ping_interval})") do |v|
    settings.ping_interval = v.to_f
  end

  opts.on("-m", "--max-iterations MAX_ITERATIONS", "How many events to distribute per action (default #{settings.max_iterations})") do |v|
    settings.max_iterations = v.to_i
  end

  opts.on("-v", "--verbose", "Be verbose") do |verbose|
    $DYNFLOW_BENCHMARK_VERBOSE = true
  end


end.parse!

ENV['DB_CONN_STRING'] ||= settings.connection_string

class SampleAction < Dynflow::Action
  def plan(sub_actions_count: 2,
           step_duration: 0.5,
           step_duration_range: nil,
           ping_interval: 0.5,
           max_iterations: 2)
    puts "Planning action: #{execution_plan_id}"
    sub_actions_count.times do
      plan_action(SampleSubAction,
                  step_duration: step_duration,
                  step_duration_range: step_duration_range,
                  ping_interval: ping_interval,
                  max_iterations: max_iterations)
    end
    plan_self
  end

  def run
    puts "Running action: #{execution_plan_id}"
  end
end

class SampleSubAction < Dynflow::Action
  def run(event = nil)
    output[:iteration] ||= 0
    output[:iteration] += 1
    if output[:iteration] < max_iterations
      sleep step_duration
      world.clock.ping(suspended_action, ping_interval, 'event')
      suspend
    end
  end

  def max_iterations
    input.fetch(:max_iterations)
  end

  def ping_interval
    input.fetch(:ping_interval)
  end

  def step_duration
    if input[:step_duration_range]
      rand(input[:step_duration_range])
    else
      input.fetch(:step_duration)
    end
  end

  def finalize
    sleep step_duration
  end
end

class BenchmarkReport
  def initialize(started_at, client, settings)
    @started_at = started_at
    @ended_at = Time.now
    @client = client
    @settings = settings
  end

  def report
    load_execution_plans
    if @plans.empty?
      puts "No plans found, probably something went wrong"
    end

    plans_by_real_time = @plans.sort_by(&:real_time)
    print_row("plans", @plans.size)
    print_row("duration", duration)
    print_row("max_realtime", plans_by_real_time.last.real_time)
    print_row("min_realtime", plans_by_real_time.first.real_time)
    print_row("med_realtime", plans_by_real_time[plans_by_real_time.size/2].real_time)
  end

  def duration
    @ended_at - @started_at
  end

  def print_row(label, value)
    printf("| %-20s | %-20s |\n", label, value)
  end

  # Loads execution plans that were started after @started_at time
  def load_execution_plans
    per_page = 100
    page = 0
    @plans = []
    until (plans = persistence.find_execution_plans(page: page, per_page: per_page, order_by: 'started_at', desc: true)).empty?
      plans.each do |plan|
        if plan.started_at > (@started_at - 5) # tolerating 5 seconds before the started_at value
          @plans << plan
        else
          return @plans
        end
      end
      page += 1
    end
    return @plans
  end

  def persistence
    @client.persistence
  end
end

class Benchmark
  include LoggerHelper
  attr_reader :settings

  def initialize(settings)
    @settings = settings
    @service_pids = []
    @client_pids = []
  end

  def run
    puts "The benchmark is starting…"
    fork_client { BenchmarkHelper.ensure_db_prepared }
    wait_for_clients
    fork_service { BenchmarkHelper.run_observer }
    settings.executors_count.times do
      fork_service { BenchmarkHelper.run_executor }
    end
    wait_for_executors
    @started_at = Time.now
    settings.clients_count.times do
      fork_client { Benchmark.run_client(settings) }
    end
    wait_for_clients
    report
  rescue Exception => e
    puts "Unexpected error: #{e.message}"
    puts e.backtrace.join("\n")
  ensure
    kill_services
  end

  def report
    with_client do |client|
      BenchmarkReport.new(@started_at, client, settings).report
    end
  end

  def with_client(&block)
    BenchmarkHelper.with_client(&block)
  end

  def wait_for_executors
    with_client do |client|
      logger.debug("waiting for executors")
      wait_for("executors") do
        current_count = client.coordinator.find_worlds(true).size
        if current_count == settings.executors_count
          true
        else
          logger.debug("executors not ready (expected #{settings.executors_count}, currently #{current_count}})")
          false
        end
      end
    end
  end

  def wait_for(description, timeout = 60, &block)
    started_at = Time.now
    until block.call
      raise "Waiting for #{description} failed" if Time.now - started_at > timeout
      sleep 0.5
    end
  end

  def self.run_client(settings)
    client = BenchmarkHelper.create_client
    latch = Concurrent::CountDownLatch.new(settings.plans_count)
    settings.plans_count.times do
      execution = client.trigger(SampleAction, settings.action_options)
      on_fulfillment_block = Proc.new do
        latch.count_down
        puts "Pending #{latch.count}"
      end
      if execution.finished.respond_to?(:on_completion!)
        execution.finished.on_completion!(&on_fulfillment_block)
      else
        execution.finished.on_fulfillment!(&on_fulfillment_block)
      end
    end
    latch.wait
  end

  def fork_service(&block)
    @service_pids << fork do
      STDIN.reopen('/dev/null')
      block.call
    end
  end

  def kill_services
    @service_pids.each do |pid|
      Process.kill('INT', pid)
      Process.wait(pid)
    end
  end

  def fork_client(&block)
    @client_pids << fork do
      STDIN.reopen('/dev/null')
      block.call
    end
  end

  def wait_for_clients
    @client_pids.each do |pid|
      Process.wait(pid)
    end
    @client_pids = []
  end

end

if settings.observer_only
  BenchmarkHelper.run_observer
elsif settings.executor_only
  BenchmarkHelper.run_executor
elsif settings.client_only
  Benchmark.run_client(settings)
else
  Benchmark.new(settings).run
end
