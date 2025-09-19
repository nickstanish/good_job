#!/usr/bin/env ruby
# frozen_string_literal: true

# Load the demo Rails environment
demo_path = File.expand_path('demo', File.dirname(__FILE__))
Dir.chdir(demo_path)

require File.join(demo_path, 'config', 'environment')
require 'benchmark'
require 'concurrent'
require 'securerandom'

# Simple no-op job for benchmarking
class BenchmarkJob < ActiveJob::Base
  queue_as :default

  def perform(*args)
    true
  end
end

def list_good_job_indexes
  puts 'GoodJob indexes:'
  indexes = ActiveRecord::Base.connection.execute("SELECT * FROM pg_indexes WHERE tablename = 'good_jobs' ORDER BY indexname ASC")
  indexes.each do |index|
    puts "    #{index['indexname']}:\n\t#{index['indexdef']}"
  end
end

def activate_v1_indexes
  ActiveRecord::Base.connection.execute('CREATE INDEX IF NOT EXISTS index_good_jobs_jobs_on_priority_created_at_when_unfinished ON public.good_jobs USING btree (priority DESC NULLS LAST, created_at) WHERE (finished_at IS NULL)')
  ActiveRecord::Base.connection.execute('CREATE INDEX IF NOT EXISTS index_good_jobs_on_priority_scheduled_at_unfinished_unlocked ON public.good_jobs USING btree (priority, scheduled_at) WHERE ((finished_at IS NULL) AND (locked_by_id IS NULL))')
  ActiveRecord::Base.connection.execute('CREATE INDEX IF NOT EXISTS index_good_job_jobs_for_priority_candidate_lookup ON public.good_jobs USING btree (priority, created_at) INCLUDE (id, queue_name, scheduled_at) WHERE (finished_at IS NULL)')
  ActiveRecord::Base.connection.execute('CREATE INDEX IF NOT EXISTS index_good_job_jobs_for_scheduled_candidate_lookup ON public.good_jobs USING btree (queue_name, scheduled_at, created_at) INCLUDE (id, priority) WHERE (finished_at IS NULL)')
end

def deactivate_v1_indexes
  ActiveRecord::Base.connection.execute('DROP INDEX IF EXISTS index_good_jobs_jobs_on_priority_created_at_when_unfinished')
  ActiveRecord::Base.connection.execute('DROP INDEX IF EXISTS index_good_jobs_on_priority_scheduled_at_unfinished_unlocked')
  ActiveRecord::Base.connection.execute('DROP INDEX IF EXISTS index_good_job_jobs_for_priority_candidate_lookup')
  ActiveRecord::Base.connection.execute('DROP INDEX IF EXISTS index_good_job_jobs_for_scheduled_candidate_lookup')
end

def activate_v2_indexes
  ActiveRecord::Base.connection.execute('CREATE INDEX IF NOT EXISTS index_good_jobs_jobs_testing_on_scheduled_at_candidate ON public.good_jobs USING btree (scheduled_at, queue_name) INCLUDE(id) WHERE (finished_at IS NULL)')
end

def deactivate_v2_indexes
  ActiveRecord::Base.connection.execute('DROP INDEX IF EXISTS index_good_jobs_jobs_testing_on_scheduled_at_candidate')
end

def analyze
  ActiveRecord::Base.connection.execute('ANALYZE good_jobs')
end

class DequeuePerformanceBenchmark
  THREAD_COUNTS = [2].freeze
  JOB_COUNTS = [1000, 5000, 20000].freeze

  # Configuration combinations to test
  CONFIGURATIONS = [
    {
      name: "priority_optimized",
      enable_priority: true,
      enable_dequeue_schedule_ordered: false,
      queue_select_limit: 1000,
      setup: proc { |benchmark|
        deactivate_v2_indexes
        activate_v1_indexes
        analyze
      },
    },
    {
      name: "schedule_optimized",
      enable_priority: false,
      enable_dequeue_schedule_ordered: true,
      queue_select_limit: 1000,
      setup: proc { |benchmark|
        deactivate_v1_indexes
        activate_v2_indexes
        analyze
      },
    },
  ].freeze

  def initialize
    setup_database
    @results = []
  end

  def run_benchmark
    puts "=" * 80
    puts "GoodJob perform_with_advisory_lock Benchmark"
    puts "=" * 80
    puts "Ruby: #{RUBY_VERSION}"
    puts "Rails: #{Rails.version}"
    puts "GoodJob: #{GoodJob::VERSION}"
    puts "Database: #{ActiveRecord::Base.connection.adapter_name}"
    puts

    CONFIGURATIONS.each_with_index do |config, config_index|
      puts "\n" + ("=" * 60)
      puts "Configuration #{config_index + 1}: #{config[:name]}"
      puts "Description: Priority=#{config[:enable_priority]}, Schedule=#{config[:enable_dequeue_schedule_ordered]}, Limit=#{config[:queue_select_limit]}"
      puts "=" * 60

      # Run setup proc if provided
      config[:setup]&.call(self)

      # Clean up before all tests of configuration
      GoodJob::Job.delete_all

      list_good_job_indexes
      configure_good_job(config)

      JOB_COUNTS.each do |job_count|
        puts "\nTesting with #{job_count} jobs:"
        puts "-" * 40

        THREAD_COUNTS.each do |thread_count|
          result = benchmark_configuration(job_count, thread_count)
          result[:config_name] = config[:name]
          result[:job_count] = job_count
          result[:thread_count] = thread_count
          @results << result
          puts format_result(job_count, thread_count, result)
        end
      end
    end

    print_summary
  end

  def print_summary
    puts "\n" + ("=" * 80)
    puts "PERFORMANCE SUMMARY"
    puts "=" * 80

    # Group results by job count and thread count
    JOB_COUNTS.each do |job_count|
      puts "\n#{job_count} Jobs Performance Comparison:"
      puts "-" * 50

      THREAD_COUNTS.each do |thread_count|
        results_for_scenario = @results.select { |r| r[:job_count] == job_count && r[:thread_count] == thread_count }

        priority_result = results_for_scenario.find { |r| r[:config_name] == "priority_optimized" }
        schedule_result = results_for_scenario.find { |r| r[:config_name] == "schedule_optimized" }

        next unless priority_result && schedule_result

        priority_jps = priority_result[:jobs_per_second]
        schedule_jps = schedule_result[:jobs_per_second]
        improvement = ((schedule_jps - priority_jps) / priority_jps * 100).round(1)

        winner = schedule_jps > priority_jps ? "Schedule" : "Priority"
        symbol = schedule_jps > priority_jps ? "🟢" : "🔴"

        puts format(
          "%2d threads: Priority=%6.1f j/s | Schedule=%6.1f j/s | %s %s wins by %+.1f%%",
          thread_count,
          priority_jps,
          schedule_jps,
          symbol,
          winner,
          improvement.abs
        )
      end
    end

    # Overall best configuration
    puts "\n" + ("=" * 50)
    puts "OVERALL BEST CONFIGURATIONS:"
    puts "=" * 50

    best_overall = @results.max_by { |r| r[:jobs_per_second] }
    puts "🏆 Best Overall: #{best_overall[:config_name]} with #{best_overall[:thread_count]} threads"
    puts "   Performance: #{best_overall[:jobs_per_second].round(1)} jobs/sec (#{best_overall[:job_count]} jobs)"

    # Best by job count
    JOB_COUNTS.each do |job_count|
      job_results = @results.select { |r| r[:job_count] == job_count }
      best_for_job_count = job_results.max_by { |r| r[:jobs_per_second] }
      puts "🎯 Best for #{job_count} jobs: #{best_for_job_count[:config_name]} with #{best_for_job_count[:thread_count]} threads (#{best_for_job_count[:jobs_per_second].round(1)} j/s)"
    end
  end

  private

  def setup_database
    # Clean up any existing jobs
    GoodJob::Job.delete_all
  end

  def configure_good_job(config)
    # Apply configuration, excluding non-GoodJob keys
    goodjob_config = config.reject { |key, _| [:name, :setup].include?(key) }
    goodjob_config.each do |key, value|
      GoodJob.configuration.options[key] = value
    end
  end

  def benchmark_configuration(job_count, thread_count)
    # Bulk insert jobs directly into the database
    puts "  Creating #{job_count} jobs..."
    bulk_insert_jobs(job_count)

    puts "  Enqueued #{job_count} jobs"

    # Track performance metrics
    start_time = Time.current
    jobs_processed = Concurrent::AtomicFixnum.new(0)
    threads = []
    progress_thread = nil

    # Start progress monitoring thread
    progress_thread = Thread.new do
      Thread.current.name = "progress-monitor"
      last_count = 0

      loop do
        sleep 60
        current_count = jobs_processed.value
        elapsed = Time.current - start_time
        rate = current_count / elapsed

        puts "    Progress: #{current_count}/#{job_count} jobs completed (#{rate.round(1)} j/s) - #{elapsed.round(1)}s elapsed"

        # Stop if all jobs are done
        break if current_count >= job_count

        last_count = current_count
      end
    rescue StandardError => e
      # Silently handle thread interruption
    end

    # Create worker threads
    thread_count.times do |thread_id|
      threads << Thread.new do
        Thread.current.name = "worker-#{thread_id}"

        loop do
          result = GoodJob::Job.perform_with_advisory_lock(
            lock_id: "benchmark-process-#{thread_id}",
            parsed_queues: nil,
            queue_select_limit: GoodJob.configuration.queue_select_limit
          )

          break unless result

          jobs_processed.increment

          # No more jobs available
        end
      rescue StandardError => e
        puts "Thread #{thread_id} error: #{e.message}"
      end
    end

    # Wait for all threads to complete
    threads.each(&:join)

    # Stop progress monitoring
    progress_thread&.kill
    progress_thread&.join(1)

    end_time = Time.current
    duration = end_time - start_time

    # Verify all jobs were processed
    remaining_jobs = GoodJob::Job.unfinished.count

    {
      duration: duration,
      jobs_processed: jobs_processed.value,
      remaining_jobs: remaining_jobs,
      jobs_per_second: jobs_processed.value / duration,
      avg_time_per_job: duration / jobs_processed.value,
    }
  end

  def bulk_insert_jobs(job_count)
    # Create job records in batches for better performance
    batch_size = 1000
    now = Time.current

    (0...job_count).each_slice(batch_size) do |batch_indices|
      job_records = batch_indices.map do |i|
        job_id = SecureRandom.uuid
        {
          id: job_id,
          active_job_id: job_id,
          queue_name: 'default',
          job_class: 'BenchmarkJob',
          serialized_params: {
            job_class: 'BenchmarkJob',
            job_id: job_id,
            provider_job_id: job_id,
            queue_name: 'default',
            arguments: ["job_#{i}"],
            executions: 0,
            exception_executions: {},
            locale: 'en',
            timezone: 'UTC',
            enqueued_at: now.iso8601,
          }.to_json,
          scheduled_at: now,
          created_at: now,
          priority: 0,
        }
      end

      # Use bulk insert
      GoodJob::Job.insert_all(job_records)
    end
  end

  def format_result(job_count, thread_count, result)
    format(
      "  %2d threads: %6.2fs | %6.1f jobs/sec | %6.3fs/job | %d/%d processed",
      thread_count,
      result[:duration],
      result[:jobs_per_second],
      result[:avg_time_per_job],
      result[:jobs_processed],
      job_count
    )
  end
end

# Main execution
if __FILE__ == $0
  begin
    benchmark = DequeuePerformanceBenchmark.new
    benchmark.run_benchmark
  rescue StandardError => e
    puts "Benchmark failed: #{e.message}"
    puts e.backtrace.first(10)
    exit 1
  end
end
