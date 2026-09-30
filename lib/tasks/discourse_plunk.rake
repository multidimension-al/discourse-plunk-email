# frozen_string_literal: true

desc "Replay known historical Plunk feedback: rake 'plunk_feedback:replay[complaint,/shared/plunk-complaints.json]'"
task "plunk_feedback:replay", %i[route path] => :environment do |_, args|
  route = args[:route].to_s
  path = args[:path].to_s
  if DiscoursePlunk::ROUTES.keys.exclude?(route) || path.blank?
    abort "usage: rake 'plunk_feedback:replay[unsubscribe|complaint|bounce,/path/to/file.json]'"
  end
  abort "file not found: #{path}" if !File.file?(path)
  abort "enable plunk_feedback_enabled first" if !SiteSetting.plunk_feedback_enabled

  outcomes = DiscoursePlunk::Backfill.run(route, path)
  outcomes.each do |o|
    puts [
           "record #{o.index}",
           o.status,
           o.receipt_id ? "receipt ##{o.receipt_id}" : nil,
           o.detail,
         ].compact.join(" | ")
  end
  puts "#{outcomes.size} record(s); see Admin → Plugins → Plunk feedback for details"
end

desc "Re-run one Plunk feedback receipt through the processor: rake 'plunk_feedback:reprocess[123]'"
task "plunk_feedback:reprocess", %i[id] => :environment do |_, args|
  abort "enable plunk_feedback_enabled first" if !SiteSetting.plunk_feedback_enabled
  event = DiscoursePlunk::FeedbackEvent.find(args[:id])
  event = DiscoursePlunk::Processor.process(event, trigger: :admin)
  puts "receipt ##{event.id}: #{event.status} (#{event.outcome})"
end
