require "spec_helper"
require "dea/nats"
require "dea/responders/async_stage"

describe Dea::Responders::AsyncStage do
  let(:nats) { mock(:nats) }
  let(:config) { {} }
  let(:bootstrap) { mock(:bootstrap, :config => config) }
  subject { described_class.new(nats, bootstrap, config) }

  describe "#start" do
    let(:nats) { NatsClientMock.new }

    context "when config does not allow staging operations" do
      let(:config) { {} }

      it "does not listen to staging" do
        subject.start
        subject.should_not_receive(:handle)
        nats.publish("staging.async")
      end
    end

    context "when the config allows staging operation" do
      let(:config) { {"staging" => {"enabled" => true}} }

      it "subscribes to staging message" do
        subject.start
        subject.should_receive(:handle)
        nats.publish("staging.async")
      end

      it "subscribes to staging message as part of the queue group" do
        nats.should_receive(:subscribe).with("staging.async", hash_including(:queue => "staging.async"))
        subject.start
      end

      it "subscribes to staging message but manually tracks the subscription" do
        nats.should_receive(:subscribe).with("staging.async", hash_including(:do_not_track_subscription => true))
        subject.start
      end
    end
  end

  describe "#stop" do
    let(:nats) { NatsClientMock.new }
    let(:config) { {"staging" => {"enabled" => true}} }

    context "when subscription was made" do
      before { subject.start }

      it "unsubscribes to staging message" do
        subject.should_receive(:handle) # sanity check
        nats.publish("staging.async")

        subject.stop
        subject.should_not_receive(:handle)
        nats.publish("staging.async")
      end
    end

    context "when subscription was not made" do
      it "does not unsubscribe" do
        nats.should_not_receive(:unsubscribe)
        subject.stop
      end
    end
  end

  describe "#handle" do
    let(:message) { Dea::Nats::Message.new(nats, nil, {"something" => "value"}, "respond-to") }
    let(:staging_task) { mock(:staging_task, :task_id => "task-id") }

    before { Dea::StagingTask.stub(:new => staging_task) }

    before do
      staging_task.stub(:after_setup)
      staging_task.stub(:start)
    end

    it "starts staging task" do
      Dea::StagingTask
        .should_receive(:new)
        .with(bootstrap, message.data)
        .and_return(staging_task)
      staging_task.should_receive(:start)
      subject.handle(message)
    end

    context "when staging succeeds setting up staging container" do
      before do
        staging_task.stub(:streaming_log_url).and_return("streaming-log-url")
        staging_task.stub(:after_setup).and_yield(nil)
      end

      it "responds with successful message" do
        nats.should_receive(:publish).with("respond-to", {
          "task_id" => "task-id",
          "streaming_log_url" => "streaming-log-url",
          "error" => nil
        })
        subject.handle(message)
      end
    end

    context "when staging fails to set up staging container" do
      before do
        staging_task.stub(:streaming_log_url).and_return(nil)
        staging_task.stub(:after_setup).and_yield(RuntimeError.new("error-description"))
      end

      it "responds with error message" do
        nats.should_receive(:publish).with("respond-to", {
          "task_id" => "task-id",
          "streaming_log_url" => nil,
          "error" => "error-description",
        })
        subject.handle(message)
      end
    end
  end
end