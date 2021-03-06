# frozen_string_literal: true

describe Delayed::JobGroups::Plugin do
  before do
    @old_max_attempts = Delayed::Worker.max_attempts
    Delayed::Worker.max_attempts = 2

    CompletionJob.invoked = false
    CancellationJob.invoked = false
  end

  after do
    Delayed::Worker.max_attempts = @old_max_attempts
  end

  let!(:job_group) { Delayed::JobGroups::JobGroup.create!(on_completion_job: CompletionJob.new) }

  it "runs the completion job after completing other jobs" do
    job_group.enqueue(NoOpJob.new)
    job_group.enqueue(NoOpJob.new)
    job_group.mark_queueing_complete
    expect(job_group_count).to eq 1
    expect(queued_job_count).to eq 2

    # Run our first job
    Delayed::Worker.new.work_off(1)
    expect(CompletionJob.invoked).to be(false)
    expect(job_group_count).to eq 1
    expect(queued_job_count).to eq 1

    # Run our second job which should enqueue the completion job
    Delayed::Worker.new.work_off(1)
    expect(CompletionJob.invoked).to be(false)
    expect(job_group_count).to eq 0
    expect(queued_job_count).to eq 1

    # Now we should run the completion job
    Delayed::Worker.new.work_off(1)
    expect(CompletionJob.invoked).to be(true)
    expect(queued_job_count).to eq 0
  end

  it "only runs the completion job after queueing is completed" do
    job_group.enqueue(NoOpJob.new)
    job_group.enqueue(NoOpJob.new)
    expect(job_group_count).to eq 1
    expect(queued_job_count).to eq 2

    # Run our first job
    Delayed::Worker.new.work_off(1)
    expect(CompletionJob.invoked).to be(false)
    expect(job_group_count).to eq 1
    expect(queued_job_count).to eq 1

    # Run our second job
    Delayed::Worker.new.work_off(1)
    expect(CompletionJob.invoked).to be(false)
    expect(job_group_count).to eq 1
    expect(queued_job_count).to eq 0

    # Mark queueing complete which should queue the completion job
    job_group.mark_queueing_complete
    expect(job_group_count).to eq 0
    expect(queued_job_count).to eq 1

    # Now we should run the completion job
    Delayed::Worker.new.work_off(1)
    expect(CompletionJob.invoked).to be(true)
    expect(queued_job_count).to eq 0
  end

  describe "job failures" do

    context "with failure_cancels_group enabled" do
      it "cancels the group" do
        Delayed::Worker.max_attempts = 1

        job_group.enqueue(FailingJob.new)
        job_group.enqueue(NoOpJob.new)
        job_group.mark_queueing_complete
        expect(queued_job_count).to eq 2
        expect(job_group_count).to eq 1

        # Run the job which should fail and cancel the JobGroup
        Delayed::Worker.new.work_off(1)
        expect(CompletionJob.invoked).to be(false)
        expect(failed_job_count).to eq 1
        expect(queued_job_count).to eq 0
        expect(job_group_count).to eq 0
      end
    end

    context "with failure_cancels_group disabled" do

      before { job_group.update_attributes!(failure_cancels_group: false) }

      it "does not cancel the group" do
        Delayed::Worker.max_attempts = 1

        job_group.enqueue(FailingJob.new)
        job_group.enqueue(NoOpJob.new)
        job_group.mark_queueing_complete
        expect(queued_job_count).to eq 2
        expect(job_group_count).to eq 1

        # Run the job which should fail don't cancel the JobGroup
        Delayed::Worker.new.work_off(1)
        expect(CancellationJob.invoked).to be(false)
        expect(failed_job_count).to eq 1
        expect(queued_job_count).to eq 1
        expect(job_group_count).to eq 1
      end
    end
  end

  it "doesn't retry failed jobs if the job group has been canceled" do
    job_group.cancel
    Delayed::Job.enqueue(FailingJob.new, job_group_id: job_group.id)
    expect(queued_job_count).to eq 1

    # Run the job which should fail and should not queue a retry
    Delayed::Worker.new.work_off(1)
    expect(failed_job_count).to eq 1
    expect(queued_job_count).to eq 0
  end

  it "doesn't run jobs until they're unblocked" do
    job_group.blocked = true
    job_group.save!

    job_group.enqueue(NoOpJob.new)
    job_group.enqueue(NoOpJob.new)
    job_group.mark_queueing_complete
    expect(Delayed::Job.count).to eq 2

    # No jobs should run because they're blocked
    (successes, failures) = Delayed::Worker.new.work_off
    expect(successes).to eq 0
    expect(failures).to eq 0
    expect(Delayed::Job.count).to eq 2

    job_group.unblock

    # Run our first job
    Delayed::Worker.new.work_off(1)
    expect(CompletionJob.invoked).to be(false)
    expect(job_group_count).to eq 1
    expect(Delayed::Job.count).to eq 1

    # Run our second job which should enqueue the completion job
    Delayed::Worker.new.work_off(1)
    expect(CompletionJob.invoked).to be(false)
    expect(job_group_count).to eq 0
    expect(Delayed::Job.count).to eq 1

    # Now we should run the completion job
    Delayed::Worker.new.work_off(1)
    expect(CompletionJob.invoked).to be(true)
    expect(Delayed::Job.count).to eq 0
  end

  context "when a cancellation job is provided" do
    let!(:job_group) do
      Delayed::JobGroups::JobGroup.create!(on_completion_job: CompletionJob.new,
                                           on_cancellation_job: CancellationJob.new)
    end

    it "runs the cancellation job after a job error causes cancellation" do
      Delayed::Worker.max_attempts = 1

      job_group.enqueue(FailingJob.new)
      job_group.enqueue(NoOpJob.new)
      job_group.mark_queueing_complete
      expect(queued_job_count).to eq 2
      expect(job_group_count).to eq 1

      # Run the job which should fail and cancel the JobGroup
      Delayed::Worker.new.work_off(1)
      expect(CompletionJob.invoked).to be(false)
      expect(CancellationJob.invoked).to be(false)
      expect(failed_job_count).to eq 1

      expect(queued_job_count).to eq 1
      expect(job_group_count).to eq 0

      # Now we should run the cancellation job
      Delayed::Worker.new.work_off(1)
      expect(CompletionJob.invoked).to be(false)
      expect(CancellationJob.invoked).to be(true)
      expect(queued_job_count).to eq 0
    end

    it "runs the cancellation job after the job group is cancelled" do
      job_group.enqueue(NoOpJob.new)
      job_group.enqueue(FailingJob.new)
      job_group.mark_queueing_complete
      job_group.cancel

      # cancellation job should be queued
      expect(queued_job_count).to eq 1
      expect(CancellationJob.invoked).to be(false)

      # Run the cancellation job
      Delayed::Worker.new.work_off(1)
      expect(CancellationJob.invoked).to be(true)
      expect(queued_job_count).to eq 0
    end
  end

  context "when a no completion job is provided" do
    let!(:job_group) {  Delayed::JobGroups::JobGroup.create! }

    it "doesn't queue a non-existent completion job" do
      job_group.enqueue(NoOpJob.new)
      job_group.enqueue(NoOpJob.new)
      job_group.mark_queueing_complete
      expect(job_group_count).to eq 1
      expect(queued_job_count).to eq 2
      expect(failed_job_count).to eq 0

      # Run our first job
      Delayed::Worker.new.work_off(1)
      expect(job_group_count).to eq 1
      expect(queued_job_count).to eq 1
      expect(failed_job_count).to eq 0

      # Run our second job which should delete the job group
      Delayed::Worker.new.work_off(1)
      expect(job_group_count).to eq 0
      expect(queued_job_count).to eq 0
      expect(failed_job_count).to eq 0
    end
  end

  class FailingJob

    def perform
      raise 'Test failure'
    end

  end

  class NoOpJob

    def perform

    end
  end

  class CompletionJob
    cattr_accessor :invoked

    def perform
      CompletionJob.invoked = true
    end
  end

  class CancellationJob
    cattr_accessor :invoked

    def perform
      CancellationJob.invoked = true
    end
  end

  def job_group_count
    Delayed::JobGroups::JobGroup.count
  end

  def queued_job_count
    Delayed::Job.where(failed_at: nil).count
  end

  def failed_job_count
    Delayed::Job.where('failed_at IS NOT NULL').count
  end
end
