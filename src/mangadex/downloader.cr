require "./api"
require "sqlite3"

module MangaDex
	class PageJob
		property success = false
		property url : String
		property filename : String
		property writer : Zip::Writer
		property tries_remaning : Int32
		def initialize(@url, @filename, @writer, @tries_remaning)
		end
	end

	enum JobStatus
		Pending      # 0
		Downloading  # 1
		Error        # 2
		Completed    # 3
		MissingPages # 4
	end

	struct Job
		property id : String
		property manga_id : String
		property title : String
		property manga_title : String
		property status : JobStatus
		property status_message : String = ""
		property pages : Int32 = 0
		property success_count : Int32 = 0
		property fail_count : Int32 = 0
		property time : Time

		def parse_query_result(res : DB::ResultSet)
			begin
				@id = res.read String
				@manga_id = res.read String
				@title = res.read String
				@manga_title = res.read String
				status = res.read Int32
				@status_message = res.read String
				@pages = res.read Int32
				@success_count = res.read Int32
				@fail_count = res.read Int32
				time = res.read Int64
				@status = JobStatus.new status
				@time = Time.unix_ms time
				return true
			rescue e
				puts e
				return false
			end
		end

		def self.from_query_result(res : DB::ResultSet)
			job = Job.allocate
			success = job.parse_query_result res
			return success ? job : nil
		end

		def initialize(@id, @manga_id, @title, @manga_title, @status, @time)
		end

		def to_json(json)
			json.object do
				{% for name in ["id", "manga_id", "title", "manga_title",
					"status_message"] %}
					json.field {{name}}, @{{name.id}}
				{% end %}
				{% for name in ["pages", "success_count", "fail_count"] %}
					json.field {{name}} do
						json.number @{{name.id}}
					end
				{% end %}
				json.field "status", @status.to_s
				json.field "time" do
					json.number @time.to_unix_ms
				end
			end
		end
	end

	class Queue
		property downloader : Downloader?

		def initialize(@path : String, @logger : MLogger)
			dir = File.dirname path
			unless Dir.exists? dir
				@logger.info "The queue DB directory #{dir} does not exist. " \
					"Attepmting to create it"
				Dir.mkdir_p dir
			end
			DB.open "sqlite3://#{@path}" do |db|
				begin
					db.exec "create table if not exists queue " \
						"(id text, manga_id text, title text, manga_title " \
						"text, status integer, status_message text, " \
						"pages integer, success_count integer, " \
						"fail_count integer, time integer)"
					db.exec "create unique index if not exists id_idx " \
						"on queue (id)"
					db.exec "create index if not exists manga_id_idx " \
						"on queue (manga_id)"
					db.exec "create index if not exists status_idx " \
						"on queue (status)"
				rescue e
					@logger.error "Error when checking tables in DB: #{e}"
					raise e
				end
			end
		end

		# Returns the earliest job in queue or nil if the job cannot be parsed.
		#	Returns nil if queue is empty
		def pop
			job = nil
			DB.open "sqlite3://#{@path}" do |db|
				begin
					db.query_one "select * from queue where status = 0 "\
						"or status = 1 order by time limit 1" do |res|
						job = Job.from_query_result res
					end
				rescue
				end
			end
			return job
		end

		# Push an array of jobs into the queue, and return the number of jobs
		#	inserted. Any job already exists in the queue will be ignored.
		def push(jobs : Array(Job))
			start_count = self.count
			DB.open "sqlite3://#{@path}" do |db|
				jobs.each do |job|
					db.exec "insert or ignore into queue values "\
						"(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
						job.id, job.manga_id, job.title, job.manga_title,
						job.status.to_i, job.status_message, job.pages,
						job.success_count, job.fail_count, job.time.to_unix_ms
				end
			end
			self.count - start_count
		end

		def reset(id : String)
			DB.open "sqlite3://#{@path}" do |db|
				db.exec "update queue set status = 0, status_message = '', " \
					"pages = 0, success_count = 0, fail_count = 0 " \
					"where id = (?)", id
			end
		end

		def reset (job : Job)
			self.reset job.id
		end

		# Reset all failed tasks (missing pages and error)
		def reset
			DB.open "sqlite3://#{@path}" do |db|
				db.exec "update queue set status = 0, status_message = '', " \
					"pages = 0, success_count = 0, fail_count = 0 " \
					"where status = 2 or status = 4"
			end
		end

		def delete(id : String)
			DB.open "sqlite3://#{@path}" do |db|
				db.exec "delete from queue where id = (?)", id
			end
		end

		def delete(job : Job)
			self.delete job.id
		end

		def get(job : Job)
			DB.open "sqlite3://#{@path}" do |db|
				db.query_one "select * from queue where id = (?)", id do |res|
					job.parse_query_result res
				end
			end
		end

		def delete_status(status : JobStatus)
			DB.open "sqlite3://#{@path}" do |db|
				db.exec "delete from queue where status = (?)", status.to_i
			end
		end

		def count_status(status : JobStatus)
			DB.open "sqlite3://#{@path}" do |db|
				return db.query_one "select count(*) from queue where "\
					"status = (?)", status.to_i, as: Int32
			end
		end

		def count
			DB.open "sqlite3://#{@path}" do |db|
				return db.query_one "select count(*) from queue", as: Int32
			end
		end

		def set_status(status : JobStatus, job : Job)
			DB.open "sqlite3://#{@path}" do |db|
				db.exec "update queue set status = (?) where id = (?)",
					status.to_i, job.id
			end
		end

		def get_all
			jobs = [] of Job
			DB.open "sqlite3://#{@path}" do |db|
				jobs = db.query_all "select * from queue", do |rs|
					Job.from_query_result rs
				end
			end
			return jobs
		end

		def add_success(job : Job)
			DB.open "sqlite3://#{@path}" do |db|
				db.exec "update queue set success_count = success_count + 1 " \
					"where id = (?)", job.id
			end
		end

		def add_fail(job : Job)
			DB.open "sqlite3://#{@path}" do |db|
				db.exec "update queue set fail_count = fail_count + 1 " \
					"where id = (?)", job.id
			end
		end

		def set_pages(pages : Int32, job : Job)
			DB.open "sqlite3://#{@path}" do |db|
				db.exec "update queue set pages = (?), success_count = 0, " \
					"fail_count = 0 where id = (?)", pages, job.id
			end
		end

		def add_message(msg : String, job : Job)
			DB.open "sqlite3://#{@path}" do |db|
				db.exec "update queue set status_message = " \
					"status_message || (?) || (?) where id = (?)",
					"\n", msg, job.id
			end
		end

		def pause
			@downloader.not_nil!.stopped = true
		end

		def resume
			@downloader.not_nil!.stopped = false
		end

		def paused?
			@downloader.not_nil!.stopped
		end
	end

	class Downloader
		property stopped = false

		def initialize(@queue : Queue, @api : API, @library_path : String,
					   @wait_seconds : Int32, @retries : Int32,
					   @logger : MLogger)
			@queue.downloader = self

			spawn do
				loop do
					sleep 1.second
					next if @stopped
					begin
						job = @queue.pop
						next if job.nil?
						download job
					rescue e
						@logger.error e
					end
				end
			end
		end

		private def download(job : Job)
			@stop = true
			@queue.set_status JobStatus::Downloading, job
			begin
				chapter = @api.get_chapter(job.id)
			rescue e
				@logger.error e
				@queue.set_status JobStatus::Error, job
				unless e.message.nil?
					@queue.add_message e.message.not_nil!, job
				end
				@stop = false
				return
			end
			@queue.set_pages chapter.pages.size, job
			lib_dir = @library_path
			manga_dir = File.join lib_dir, chapter.manga.title
			unless File.exists? manga_dir
				Dir.mkdir_p manga_dir
			end
			zip_path = File.join manga_dir, "#{job.title}.cbz"

			# Find the number of digits needed to store the number of pages
			len = Math.log10(chapter.pages.size).to_i + 1

			writer = Zip::Writer.new zip_path
			# Create a buffered channel. It works as an FIFO queue
			channel = Channel(PageJob).new chapter.pages.size
			spawn do
				chapter.pages.each_with_index do |tuple, i|
					fn, url = tuple
					ext = File.extname fn
					fn = "#{i.to_s.rjust len, '0'}#{ext}"
					page_job = PageJob.new url, fn, writer, @retries
					@logger.debug "Downloading #{url}"
					loop do
						sleep @wait_seconds.seconds
						download_page page_job
						break if page_job.success ||
							page_job.tries_remaning <= 0
						page_job.tries_remaning -= 1
						@logger.warn "Failed to download page #{url}. " \
							"Retrying... Remaining retries: " \
							"#{page_job.tries_remaning}"
					end

					channel.send page_job
				end
			end

			spawn do
				page_jobs = [] of PageJob
				chapter.pages.size.times do
					page_job = channel.receive
					@logger.debug "[#{page_job.success ? "success" : "failed"}] " \
						"#{page_job.url}"
					page_jobs << page_job
					if page_job.success
						@queue.add_success job
					else
						@queue.add_fail job
						msg = "Failed to download page #{page_job.url}"
						@queue.add_message msg, job
						@logger.error msg
					end
				end
				fail_count = page_jobs.select{|j| !j.success}.size
				@logger.debug "Download completed. "\
					"#{fail_count}/#{page_jobs.size} failed"
				writer.close
				@logger.debug "cbz File created at #{zip_path}"
				if fail_count == 0
					@queue.set_status JobStatus::Completed, job
				else
					@queue.set_status JobStatus::MissingPages, job
				end
				@stop = false
			end
		end

		private def download_page(job : PageJob)
			@logger.debug "downloading #{job.url}"
			headers = HTTP::Headers {
				"User-agent" => "Mangadex.cr"
			}
			begin
				HTTP::Client.get job.url, headers do |res|
					unless res.success?
						raise "Failed to download page #{job.url}. " \
							"[#{res.status_code}] #{res.status_message}"
					end
					job.writer.add job.filename, res.body_io
				end
				job.success = true
			rescue e
				@logger.error e
				job.success = false
			end
		end
	end
end