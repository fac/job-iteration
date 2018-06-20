# frozen_string_literal: true
require 'test_helper'

class JobIteration::IterationTest < ActiveSupport::TestCase
  include JobIteration::TestHelper

  class SimpleIterationJob < ActiveJob::Base
    include JobIteration::Iteration

    cattr_accessor :records_performed, instance_accessor: false
    self.records_performed = []
    cattr_accessor :on_start_called, instance_accessor: false
    self.on_start_called = 0
    cattr_accessor :on_complete_called, instance_accessor: false
    self.on_complete_called = 0
    cattr_accessor :on_shutdown_called, instance_accessor: false
    self.on_shutdown_called = 0

    on_start do
      self.class.on_start_called += 1
    end

    on_complete do
      self.class.on_complete_called += 1
    end

    on_shutdown do
      self.class.on_shutdown_called += 1
    end
  end

  class IterationJobsWithParams < SimpleIterationJob
    def build_enumerator(params, cursor:)
      enumerator_builder.build_times_enumerator(params[0].fetch(:times, 2), cursor: cursor)
    end

    def each_iteration(_record, params)
      self.class.records_performed << params
    end
  end

  class ActiveRecordIterationJob < SimpleIterationJob
    def build_enumerator(_params, cursor:)
      enumerator_builder.build_active_record_enumerator_on_records(
        Product.all,
        cursor: cursor,
      )
    end

    def each_iteration(record, _params)
      self.class.records_performed << record
    end
  end

  class BatchActiveRecordIterationJob < SimpleIterationJob
    def build_enumerator(_params, cursor:)
      enumerator_builder.build_active_record_enumerator_on_batches(
        Product.all,
        cursor: cursor,
        batch_size: 3
      )
    end

    def each_iteration(record, _params)
      self.class.records_performed << record
    end
  end

  class AbortingActiveRecordIterationJob < ActiveRecordIterationJob
    def each_iteration(*)
      throw(:abort) if self.class.records_performed.size == 2
      super
    end
  end

  class AbortingBatchActiveRecordIterationJob < SimpleIterationJob
    def build_enumerator(_params, cursor:)
      enumerator_builder.build_active_record_enumerator_on_batches(
        Product.all,
        cursor: cursor,
        batch_size: 3
      )
    end

    def each_iteration(record, _params)
      self.class.records_performed << record
      throw(:abort) if self.class.records_performed.size == 2
    end
  end

  class OrderedActiveRecordIterationJob < SimpleIterationJob
    def build_enumerator(_params, cursor:)
      enumerator_builder.build_active_record_enumerator_on_records(
        Product.order('country DESC'),
        cursor: cursor
      )
    end

    def each_iteration(*)
    end
  end

  class LimitActiveRecordIterationJob < SimpleIterationJob
    def build_enumerator(_params, cursor:)
      enumerator_builder.build_active_record_enumerator_on_records(
        Product.limit(5),
        cursor: cursor
      )
    end

    def each_iteration(*)
    end
  end

  class MissingBuildEnumeratorJob < SimpleIterationJob
    def each_iteration(*)
    end
  end

  class NilEnumeratorIterationJob < SimpleIterationJob
    def build_enumerator(*)
    end

    def each_iteration(*)
    end
  end

  class PrivateIterationJob < SimpleIterationJob
    private

    def build_enumerator(_params, cursor:)
      enumerator_builder.build_times_enumerator(3, cursor: cursor)
    end

    def each_iteration(*)
    end
  end

  class MissingEachIterationJob < SimpleIterationJob
    def build_enumerator(_params, cursor:)
      enumerator_builder.build_times_enumerator(3, cursor: cursor)
    end
  end

  class MultipleColumnsActiveRecordIterationJob < SimpleIterationJob
    def build_enumerator(_params, cursor:)
      enumerator_builder.build_active_record_enumerator_on_records(
        Product.all,
        cursor: cursor,
        columns: [:updated_at, :id],
        batch_size: 2
      )
    end

    def each_iteration(record, _params)
      self.class.records_performed << record
    end
  end

  class SingleIterationJob < SimpleIterationJob
    def build_enumerator(_params, cursor:)
      enumerator_builder.build_once_enumerator(cursor: cursor)
    end

    def each_iteration(record, _params)
      self.class.records_performed << record
    end
  end

  class FailingIterationJob < SimpleIterationJob
    retry_on RuntimeError, attempts: 3, wait: 0

    def build_enumerator(_params, cursor:)
      enumerator_builder.build_active_record_enumerator_on_records(
        Product.all,
        cursor: cursor
      )
    end

    def each_iteration(shop, _params)
      @called ||= 0
      raise if @called > 2
      self.class.records_performed << shop
      @called += 1
    end
  end

  class JobWithBuildEnumeratorReturningArray < SimpleIterationJob
    def build_enumerator(*)
      []
    end

    def each_iteration(*)
      raise "should never be called"
    end
  end

  class JobWithBuildEnumeratorReturningActiveRecordRelation < SimpleIterationJob
    def build_enumerator(*)
      Product.all
    end

    def each_iteration(*)
      raise "should never be called"
    end
  end

  def setup
    SimpleIterationJob.descendants.each do |klass|
      klass.records_performed = []
      klass.on_start_called = 0
      klass.on_complete_called = 0
      klass.on_shutdown_called = 0
    end
    super
  end

  def test_each_iteration_method_missing
    push(MissingEachIterationJob)
    error = assert_raises(ArgumentError) do
      work_one_job
    end
    assert_match(/Iteration job \(\S+\) must implement #each_iteration/, error.to_s)
  end

  def test_build_enumerator_method_missing
    push(MissingBuildEnumeratorJob)
    error = assert_raises(ArgumentError) do
      work_one_job
    end
    assert_match(/Iteration job \(\S+\) must implement #build_enumerator/, error.to_s)
  end

  def test_build_enumerator_returns_nil
    push(NilEnumeratorIterationJob)
    work_one_job
  end

  def test_works_with_private_methods
    push(PrivateIterationJob)
    work_one_job
    assert_jobs_in_queue 0

    assert_equal 1, PrivateIterationJob.on_start_called
    assert_equal 1, PrivateIterationJob.on_complete_called
    assert_equal 1, PrivateIterationJob.on_shutdown_called
  end

  def test_failing_job
    push(FailingIterationJob)

    work_one_job
    assert_jobs_in_queue 1

    processed_records = Product.order(:id).pluck(:id)

    job = peek_into_queue
    assert_equal processed_records[2], job.cursor_position
    assert_equal 1, job.executions
    assert_equal 0, job.times_interrupted
    assert_equal 3, FailingIterationJob.records_performed.size
    assert_equal 1, FailingIterationJob.on_start_called

    work_one_job

    job = peek_into_queue
    assert_equal processed_records[5], job.cursor_position
    assert_equal 2, job.executions
    assert_equal 0, job.times_interrupted

    assert_equal 6, FailingIterationJob.records_performed.size
    assert_equal 1, FailingIterationJob.on_start_called
    assert_equal 0, FailingIterationJob.on_complete_called

    # last attempt
    assert_raises(RuntimeError) do
      work_one_job
    end
    assert_jobs_in_queue 0
  end

  def test_active_record_job
    iterate_exact_times(2.times)

    push(ActiveRecordIterationJob)

    assert_equal 0, ActiveRecordIterationJob.on_complete_called
    work_one_job

    assert_equal 2, ActiveRecordIterationJob.records_performed.size

    job = peek_into_queue
    assert_equal 1, job.times_interrupted
    assert_equal 1, job.executions
    assert_equal Product.first(2).last.id, job.cursor_position

    work_one_job
    assert_equal 4, ActiveRecordIterationJob.records_performed.size

    job = peek_into_queue
    assert_equal 2, job.times_interrupted
    assert_equal 1, job.executions
    times_interrupted, cursor = last_interrupted_job(ActiveRecordIterationJob)
    assert_equal 2, times_interrupted
    assert cursor

    assert_equal 0, ActiveRecordIterationJob.on_complete_called
    assert_equal 2, ActiveRecordIterationJob.on_shutdown_called
  end

  def test_activerecord_batches_complete
    push(BatchActiveRecordIterationJob)
    processed_records = Product.order(:id).pluck(:id)

    work_one_job
    assert_jobs_in_queue 0

    assert_equal [3, 3, 3, 1], BatchActiveRecordIterationJob.records_performed.map(&:size)
    assert_equal processed_records, BatchActiveRecordIterationJob.records_performed.flatten.map(&:id)
  end

  def test_activerecord_batches
    iterate_exact_times(1.times)

    push(BatchActiveRecordIterationJob)
    processed_records = Product.order(:id).pluck(:id)

    work_one_job
    assert_equal 1, BatchActiveRecordIterationJob.records_performed.size
    assert_equal 3, BatchActiveRecordIterationJob.records_performed.flatten.size
    assert_equal 1, BatchActiveRecordIterationJob.on_start_called

    job = peek_into_queue
    assert_equal processed_records[2], job.cursor_position
    assert_equal 1, job.times_interrupted
    assert_equal 1, job.executions

    work_one_job
    assert_equal 2, BatchActiveRecordIterationJob.records_performed.size
    assert_equal 6, BatchActiveRecordIterationJob.records_performed.flatten.size
    assert_equal 1, BatchActiveRecordIterationJob.on_start_called

    job = peek_into_queue
    assert_equal 2, job.times_interrupted
    assert_equal 1, job.executions
    assert_equal processed_records[5], job.cursor_position
    continue_iterating

    work_one_job
    assert_jobs_in_queue 0
    assert_equal 4, BatchActiveRecordIterationJob.records_performed.size
    assert_equal 10, BatchActiveRecordIterationJob.records_performed.flatten.size

    assert_equal 1, BatchActiveRecordIterationJob.on_start_called
    assert_equal 1, BatchActiveRecordIterationJob.on_complete_called
  end

  def test_multiple_columns
    iterate_exact_times(3.times)

    push(MultipleColumnsActiveRecordIterationJob)

    1.upto(3) do |iter|
      work_one_job

      job = peek_into_queue
      last_processed_record = MultipleColumnsActiveRecordIterationJob.records_performed.last
      assert_equal [last_processed_record.updated_at.to_s(:db), last_processed_record.id], job.cursor_position

      assert_equal iter * 3, MultipleColumnsActiveRecordIterationJob.records_performed.size
    end

    assert_equal Product.all.order('updated_at, id').limit(9), MultipleColumnsActiveRecordIterationJob.records_performed
  end

  def test_single_iteration
    push(SingleIterationJob)

    assert_equal 0, SingleIterationJob.on_start_called
    assert_equal 0, SingleIterationJob.on_complete_called

    work_one_job
    assert_jobs_in_queue 0
    assert_equal 1, SingleIterationJob.on_start_called
    assert_equal 1, SingleIterationJob.on_complete_called
  end

  def test_relation_with_limit
    push(LimitActiveRecordIterationJob)

    error = assert_raises(ArgumentError) do
      work_one_job
    end
    assert_match(/The relation cannot use ORDER BY or LIMIT/, error.to_s)
  end

  def test_relation_with_order
    push(OrderedActiveRecordIterationJob)

    error = assert_raises(ArgumentError) do
      work_one_job
    end
    assert_match(/The relation cannot use ORDER BY or LIMIT/, error.to_s)
  end

  def test_cannot_override_perform
    error = assert_raises(RuntimeError) do
      Class.new(SimpleIterationJob) do
        def perform(*)
        end
      end
    end
    assert_match(/cannot redefine #perform/, error.to_s)
  end

  def test_passes_params_to_each_iteration
    params = { 'walrus' => 'best' }
    push(IterationJobsWithParams, params)
    work_one_job
    assert_equal [[params], [params]], IterationJobsWithParams.records_performed
  end

  def test_passes_params_to_each_iteration_without_extra_information_on_interruption
    iterate_exact_times(1.times)
    params = { 'walrus' => 'yes', 'morewalrus' => 'si' }
    push(IterationJobsWithParams, params)

    work_one_job
    assert_equal [params], IterationJobsWithParams.records_performed

    work_one_job
    assert_equal [params, params], IterationJobsWithParams.records_performed
  end

  def test_emits_metric_when_interrupted
    skip "statsd is coming"
    iterate_exact_times(2.times)

    push(ActiveRecordIterationJob)

    assert_statsd_increment('background_queue.iteration.interrupted') do
      work_one_job
    end
  end

  def test_emits_metric_when_resumed
    skip "statsd is coming"
    iterate_exact_times(2.times)

    push(ActiveRecordIterationJob)

    assert_no_statsd_calls('background_queue.iteration.resumed') do
      work_one_job
    end

    assert_statsd_increment('background_queue.iteration.resumed') do
      work_one_job
    end
  end

  def test_log_completion_data
    skip "should log things"
    iterate_exact_times(2.times)

    push(IterationJobsWithParams)

    # assert_no_logs(:info, /\[JobIteration::Iteration\] Completed./, BackgroundQueue) do
      work_one_job
    # end

    # expected_log = /\[JobIteration::Iteration\] Completed. times_interrupted=1 total_time=\d\.\d{3}/
    # assert_logs(:info, expected_log, BackgroundQueue) do
      work_one_job
    # end
  end

  def test_aborting_in_each_iteration_job
    push(AbortingActiveRecordIterationJob)
    work_one_job
    assert_equal 2, AbortingActiveRecordIterationJob.records_performed.size
    assert_equal 1, AbortingActiveRecordIterationJob.on_complete_called
  end

  def test_aborting_in_batched_job
    push(AbortingBatchActiveRecordIterationJob)
    work_one_job
    assert_equal 2, AbortingBatchActiveRecordIterationJob.records_performed.size
    assert_equal [3, 3], AbortingBatchActiveRecordIterationJob.records_performed.map(&:size)
    assert_equal 1, AbortingBatchActiveRecordIterationJob.on_complete_called
  end

  def test_check_for_exit_after_iteration
    # supervisor = Class.new
    # Podding::Resque::WorkerSupervisor.stubs(:instance).returns(supervisor)

    push(IterationJobsWithParams, times: 3)

    # calls = sequence("calls")
    IterationJobsWithParams.any_instance.expects(:job_should_exit?).times(3).returns(false)
    # supervisor.expects(shutdown?: true).in_sequence(calls)

    work_one_job
  end

  def test_iteration_job_with_build_enumerator_returning_array
    push(JobWithBuildEnumeratorReturningArray )

    error = assert_raises(ArgumentError) do
      work_one_job
    end
    assert_match(/#build_enumerator is expected to return Enumerator object, but returned Array/, error.to_s)
  end

  def test_iteration_job_with_build_enumerator_returning_relation
    push(JobWithBuildEnumeratorReturningActiveRecordRelation)

    error = assert_raises(ArgumentError) do
      work_one_job
    end
    assert_match(/#build_enumerator is expected to return Enumerator object, but returned Product::ActiveRecord_Relation/, error.to_s)
  end

  private

  def last_interrupted_job(job_class, queue = nil)
    jobs = ActiveJob::Base.queue_adapter.enqueued_jobs
    assert_equal 1, jobs.size

    job = jobs.last
    assert_equal job_class.name, job["job_class"]

    [job["times_interrupted"], job["cursor_position"]]
  end

  def peek_into_queue
    jobs = ActiveJob::Base.queue_adapter.enqueued_jobs
    assert_operator jobs.size, :>, 0
    ActiveJob::Base.deserialize(jobs.last)
  end

  def push(job, *args)
    job.perform_later(*args)
  end

  def work_one_job
    job = ActiveJob::Base.queue_adapter.enqueued_jobs.pop
    ActiveJob::Base.execute(job)
  end

  def assert_jobs_in_queue(size, queue = nil)
    assert_equal size, ActiveJob::Base.queue_adapter.enqueued_jobs.size
  end
end