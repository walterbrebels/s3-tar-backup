require 'aws/s3'
require 'trollop'
require 's3_tar_backup/ini_parser'
require 's3_tar_backup/backup'
require 's3_tar_backup/version'
include AWS

module S3TarBackup
	extend self

	UPLOAD_TRIES = 5

	def run
		opts = Trollop::options do
			version VERSION
			banner "Backs up files to, and restores files from, Amazon's S3 storage, using tar incremental backups\n\n" \
				"Usage:\ns3-tar-backup -c config.ini [-p profile] --backup [--full] [-v]\n" \
				"s3-tar-backup -c config.ini [-p profile] --cleanup [-v]\n" \
				"s3-tar-backup -c config.ini [-p profile] --restore restore_dir\n\t[--restore_date date] [-v]\n" \
				"s3-tar-backup -c config.ini [-p profile] --backup-config [--verbose]\n" \
				"s3-tar-backup -c config.ini [-p profile] --list-backups\n\n" \
				"Option details:\n"
			opt :config, "Configuration file", :short => 'c', :type => :string, :required => true
			opt :backup, "Make an incremental backup"
			opt :full, "Make the backup a full backup"
			opt :profile, "The backup profile(s) to use (default all)", :short => 'p', :type => :strings
			opt :cleanup, "Clean up old backups"
			opt :restore, "Restore a backup to the specified dir", :type => :string
			opt :restore_date, "Restore a backup from the specified date. Format YYYYMM[DD[hh[mm[ss]]]]", :type => :string
			opt :backup_config, "Backs up the specified configuration file"
			opt :list_backups, "List the stored backup info for one or more profiles"
			opt :verbose, "Show verbose output", :short => 'v'
			conflicts :backup, :cleanup, :restore, :backup_config, :list_backups
		end


		Trollop::die "--full requires --backup" if opts[:full] && !opts[:backup]
		Trollop::die "--restore-date requires --restore" if opts[:restore_date_given] && !opts[:restore_given]
		unless opts[:backup] || opts[:cleanup] || opts[:restore_given] || opts[:backup_config] || opts[:list_backups]
			Trollop::die "Need one of --backup, --cleanup, --restore, --backup-config, --list-backups"
		end

		begin
			raise "Config file #{opts[:config]} not found" unless File.exists?(opts[:config])
			config = IniParser.new(opts[:config]).load
			profiles = opts[:profile] || config.find_sections(/^profile\./).keys.map{ |k| k.to_s.split('.', 2)[1] }
			self.connect_s3(
				ENV['AWS_ACCESS_KEY_ID'] || config['settings.aws_access_key_id'],
				ENV['AWS_SECRET_ACCESS_KEY'] || config['settings.aws_secret_access_key']
			)

			# This is a bit of a special case
			if opts[:backup_config]
				dest = config.get('settings.dest', false)
				raise "You must specify a single profile (used to determine the location to back up to) " \
					"if backing up config and dest key is not in [settings]" if !dest && profiles.count != 1
				dest ||= config["profile.#{profiles[0]}.dest"]
				puts "===== Backing up config file #{opts[:config]} ====="
				bucket, prefix = (config.get('settings.dest', false) || config["profile.#{profiles[0]}.dest"]).split('/', 2)
				puts "Uploading #{opts[:config]} to #{bucket}/#{prefix}/#{File.basename(opts[:config])}"
				self.upload(opts[:config], bucket, "#{prefix}/#{File.basename(opts[:config])}")
				return
			end

			profiles.dup.each do |profile|
				raise "No such profile: #{profile}" unless config.has_section?("profile.#{profile}")
				opts[:profile] = profile
				backup_config = self.gen_backup_config(opts[:profile], config)
				prev_backups = self.parse_objects(backup_config[:bucket], backup_config[:dest_prefix], opts[:profile])
				self.perform_backup(opts, prev_backups, backup_config) if opts[:backup]
				self.perform_cleanup(prev_backups, backup_config) if opts[:backup] || opts[:cleanup]
				self.perform_restore(opts, prev_backups, backup_config) if opts[:restore_given]
				self.perform_list_backups(prev_backups, backup_config) if opts[:list_backups]
			end
		rescue Exception => e
			Trollop::die e.to_s
		end
	end

	def connect_s3(access_key, secret_key)
		S3::Base.establish_connection!({
			:access_key_id => access_key,
			:secret_access_key => secret_key,
		})
		S3::DEFAULT_HOST.replace("s3-eu-west-1.amazonaws.com")
	end

	def gen_backup_config(profile, config)
		bucket, dest_prefix = (config.get("profile.#{profile}.dest", false) || config['settings.dest']).split('/', 2)
		backup_config = {
			:backup_dir => config.get("profile.#{profile}.backup_dir", false) || config['settings.backup_dir'],
			:name => profile,
			:sources => [*config.get("profile.#{profile}.source", [])] + [*config.get("settings.source", [])],
			:exclude => [*config.get("profile.#{profile}.exclude", [])] + [*config.get("settings.exclude", [])],
			:bucket => bucket,
			:dest_prefix => dest_prefix.chomp('/'),
			:pre_backup => [*config.get("profile.#{profile}.pre-backup", [])] + [*config.get('settings.pre-backup', [])],
			:post_backup => [*config.get("profile.#{profile}.post-backup", [])] + [*config.get('settings.post-backup', [])],
			:full_if_older_than => config.get("profile.#{profile}.full_if_older_than", false) || config['settings.full_if_older_than'],
			:remove_older_than => config.get("profile.#{profile}.remove_older_than", false) || config.get('settings.remove_older_than', false),
			:remove_all_but_n_full => config.get("profile.#{profile}.remove_all_but_n_full", false) || config.get('settings.remove_all_but_n_full', false),
			:compression => (config.get("profile.#{profile}.compression", false) || config.get('settings.compression', 'gzip')).to_sym
		}
		backup_config
	end

	def perform_backup(opts, prev_backups, backup_config)
		puts "===== Backing up profile #{backup_config[:name]} ====="
		backup_config[:pre_backup].each_with_index do |cmd, i|
			puts "Executing pre-backup hook #{i+1}"
			system(cmd)
		end
		full_required = self.full_required?(backup_config[:full_if_older_than], prev_backups)
		puts "Last full backup is too old. Forcing a full backup" if full_required && !opts[:full_backup]
		if full_required || opts[:full]
			self.backup_full(backup_config, opts[:verbose])
		else
			self.backup_incr(backup_config, opts[:verbose])
		end
		backup_config[:post_backup].each_with_index do |cmd, i|
			puts "Executing post-backup hook #{i+1}"
			system(cmd)
		end
	end

	def perform_cleanup(prev_backups, backup_config)
		puts "===== Cleaning up profile #{backup_config[:name]} ====="
		remove = []
		if age_str = backup_config[:remove_older_than]
			age = self.parse_interval(age_str)
			remove = prev_backups.select{ |o| o[:date] < age }
			# Don't want to delete anything before the last full backup
			removed = remove.slice!(remove.rindex{ |o| o[:type] == :full }..-1).count
			puts "Keeping #{removed} old backups as part of a chain"
		elsif keep_n = backup_config[:remove_all_but_n_full]
			keep_n = keep_n.to_i
			# Get the date of the last full backup to keep
			if last_full_to_keep = prev_backups.select{ |o| o[:type] == :full }[-keep_n]
				# If there is a last full one...
				remove = prev_backups.select{ |o| o[:date] < last_full_to_keep[:date] }
			end
		end
		return if remove.empty?

		puts "Removing #{remove.count} old backup files"
		remove.each do |object|
			S3::S3Object.delete("#{backup_config[:dest_prefix]}/#{object[:name]}", backup_config[:bucket])
		end
	end

	# Config should have the keys
	# backup_dir, name, soruces, exclude, bucket, dest_prefix
	def backup_incr(config, verbose=false)
		puts "Starting new incremental backup"
		backup = Backup.new(config[:backup_dir], config[:name], config[:sources], config[:exclude], config[:compression])

		# Try and get hold of the snar file
		unless backup.snar_exists?
			puts "Failed to find snar file. Attempting to download..."
			s3_snar = "#{config[:dest_prefix]}/#{backup.snar}"
			if S3::S3Object.exists?(s3_snar, config[:bucket])
				puts "Found file on S3. Downloading"
				open(backup.snar_path, 'wb') do |f|
					S3::S3Object.stream(s3_snar, config[:bucket]) do |chunk|
						f.write(chunk)
					end
				end
			else
				puts "Failed to download snar file. Defaulting to full backup"
			end
		end

		self.backup(config, backup, verbose)
	end

	def backup_full(config, verbose=false)
		puts "Starting new full backup"
		backup = Backup.new(config[:backup_dir], config[:name], config[:sources], config[:exclude], config[:compression])
		# Nuke the snar file -- forces a full backup
		File.delete(backup.snar_path) if File.exists?(backup.snar_path)
		self.backup(config, backup, verbose)
	end

	def backup(config, backup, verbose=false)
		system(backup.backup_cmd(verbose))
		puts "Uploading #{config[:bucket]}/#{config[:dest_prefix]}/#{File.basename(backup.archive)} (#{self.bytes_to_human(File.size(backup.archive))})"
		self.upload(backup.archive, config[:bucket], "#{config[:dest_prefix]}/#{File.basename(backup.archive)}")
		puts "Uploading snar (#{self.bytes_to_human(File.size(backup.snar_path))})"
		self.upload(backup.snar_path, config[:bucket], "#{config[:dest_prefix]}/#{File.basename(backup.snar)}")
		File.delete(backup.archive)
	end

	def upload(source, bucket, dest_name)
		tries = 0
		begin
			open(source) do |f|
				S3::S3Object.store(dest_name, f, bucket)
			end
		rescue S3::S3Exception => e
			tries += 1
			if tries < UPLOAD_TRIES
				puts "S3 Exception: #{e}"
				puts "Retrying #{tries}/#{UPLOAD_TRIES}..."
				retry
			else
				raise e
			end
		end

	end

	def perform_restore(opts, prev_backups, backup_config)
		puts "===== Restoring profile #{backup_config[:name]} ====="
		# If restore date given, parse
		if opts[:restore_date_given]
			m = opts[:restore_date].match(/(\d\d\d\d)(\d\d)(\d\d)?(\d\d)?(\d\d)?(\d\d)?/)
			raise "Unknown date format in --restore-to" if m.nil?
			restore_to = Time.new(*m[1..-1].map{ |s| s.to_i if s })
		else
			restore_to = Time.now
		end

		# Find the index of the first backup, incremental or full, before that date
		restore_end_index = prev_backups.rindex{ |o| o[:date] < restore_to }
		raise "Failed to find a backup for that date" unless restore_end_index

		# Find the first full backup before that one
		restore_start_index = prev_backups[0..restore_end_index].rindex{ |o| o[:type] == :full }

		restore_dir = opts[:restore].chomp('/') << '/'

		Dir.mkdir(restore_dir) unless Dir.exists?(restore_dir)
		raise "Detination dir is not a directory" unless File.directory?(restore_dir)

		prev_backups[restore_start_index..restore_end_index].each do |object|
			puts "Fetching #{backup_config[:bucket]}/#{backup_config[:dest_prefix]}/#{object[:name]} (#{self.bytes_to_human(object[:size])})"
			dl_file = "#{backup_config[:backup_dir]}/#{object[:name]}"
			open(dl_file, 'wb') do |f|
				S3::S3Object.stream("#{backup_config[:dest_prefix]}/#{object[:name]}", backup_config[:bucket]) do |chunk|
					f.write(chunk)
				end
			end
			puts "Extracting..."
			system(Backup.restore_cmd(restore_dir, dl_file, opts[:verbose]))

			File.delete(dl_file)
		end
	end

	def perform_list_backups(prev_backups, backup_config)
		# prev_backups alreays contains just the files for the current profile
		puts "===== Backups list for #{backup_config[:name]} ====="
		puts "Type: N:  Date:#{' '*18}Size:       Chain Size:   Format:\n\n"
		prev_type = ''
		total_size = 0
		chain_length = 0
		chain_cum_size = 0
		prev_backups.each do |object|
			type = object[:type] == prev_type && object[:type] == :incr ? " -- " : object[:type].to_s.capitalize
			prev_type = object[:type]
			chain_length += 1
			chain_length = 0 if object[:type] == :full
			chain_cum_size = 0 if object[:type] == :full
			chain_cum_size += object[:size]

			chain_length_str = (chain_length == 0 ? '' : chain_length.to_s).ljust(3)
			chain_cum_size_str = (object[:type] == :full ? '' : self.bytes_to_human(chain_cum_size)).ljust(8)
			puts "#{type}  #{chain_length_str} #{object[:date].strftime('%F %T')}    #{self.bytes_to_human(object[:size]).ljust(8)}    " \
				"#{chain_cum_size_str}      (#{object[:compression]})"
			total_size += object[:size]
		end
		puts "\n"
		puts "Total size: #{self.bytes_to_human(total_size)}"
		puts "\n"
	end

	def parse_objects(bucket, prefix, profile)
		objects = []
		S3::Bucket.objects(bucket, :prefix => prefix).each do |object|
			objects << Backup.parse_object(object, profile)
		end
		objects.compact.sort_by{ |o| o[:date] }
	end

	def parse_interval(interval_str)
		time = Time.now
		time -= $1.to_i if interval_str =~ /(\d+)s/
		time -= $1.to_i*60 if interval_str =~ /(\d+)m/
		time -= $1.to_i*3600 if interval_str =~ /(\d+)h/
		time -= $1.to_i*86400 if interval_str =~ /(\d+)D/
		time -= $1.to_i*604800 if interval_str =~ /(\d+)W/
		time -= $1.to_i*2592000 if interval_str =~ /(\d+)M/
		time -= $1.to_i*31536000 if interval_str =~ /(\d+)Y/
		time
	end

	def full_required?(interval_str, objects)
		time = self.parse_interval(interval_str)
		objects.select{ |o| o[:type] == :full && o[:date] > time }.empty?
	end

	def bytes_to_human(n)
		count = 0
		while n >= 1014 && count < 4
			n /= 1024.0
			count += 1
		end
		format("%.2f", n) << %w(B KB MB GB TB)[count]
	end

end