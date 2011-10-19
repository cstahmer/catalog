# encoding: UTF-8
##########################################################################
# Copyright 2011 Applied Research in Patacriticism and the University of Virginia
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
##########################################################################

require "#{Rails.root}/lib/tasks/task_reporter.rb"
require "#{Rails.root}/lib/tasks/task_utilities.rb"

namespace :solr_index do
	def get_folders(path, archive)
		folder_file = File.join(path, "sitemap.yml")
		site_map = YAML.load_file(folder_file)
		rdf_folders = site_map['archives']
		all_enum_archives = {}
		rdf_folders.each { |k, f|
			if f.kind_of?(String)
				all_enum_archives[k] = f
			else
				all_enum_archives.merge!(f)
			end
		}
		folders = all_enum_archives[archive]
		if folders == nil
			return {:error => "The archive \"#{archive}\" was not found in #{folder_file}"}
		end
		return {:folders => folders[0].split(';'), :page_size => folders[1]}
	end

	desc "create complete reindexing task list"
	task :create_reindexing_task_list => :environment do
		#solr = CollexEngine.factory_create(false)
		#archives = solr.get_all_archives()

		folder_file = File.join(RDF_PATH, "sitemap.yml")
		site_map = YAML.load_file(folder_file)
		rdf_folders = site_map['archives']
		sh_all = TaskUtilities.create_sh_file("batch_all")

		# the archives found need to exactly match the archives in the site maps.
		all_enum_archives = {}
		rdf_folders.each { |k,f|
			all_enum_archives.merge!(f)
		}
		#all_enum_archives.merge!(marc_folders)
		#archives.each {|archive|
		#	if archive.index("exhibit_") != 0 && archive != "ECCO" && all_enum_archives[archive] == nil
		#		puts "Missing archive #{archive} from the sitemap.yml files"
		#	end
		#}
		#all_enum_archives.each {|k,v|
		#	if !archives.include?(k)
		#		puts "Archive #{k} in sitemap missing from deployed index"
		#	end
		#}

		sh_clr = TaskUtilities.create_sh_file("clear_archives")
		#core_archives = CollexEngine.get_archive_core_list()
		#core_archives.each {|archive|
		#}
		sh_merge = TaskUtilities.create_sh_file("merge_all")
		merge_list = []

		rdf_folders.each { |i, rdfs|
			sh_rdf = TaskUtilities.create_sh_file("batch#{i+1}")
			rdfs.each {|archive,f|
				sh_clr.puts("curl #{SOLR_URL}/#{archive}/update?stream.body=%3Cdelete%3E%3Cquery%3E*:*%3C/query%3E%3C/delete%3E\n")
				sh_clr.puts("curl #{SOLR_URL}/#{archive}/update?stream.body=%3Ccommit%3E%3C/commit%3E\n")

				sh_rdf.puts("rake \"archive=#{archive}\" solr_index:index_and_test\n")
				sh_all.puts("rake \"archive=#{archive}\" solr_index:index_and_test\n")

				merge_list.push(archive)
				if merge_list.length > 10
					sh_merge.puts("rake solr_index:merge_archive archive=\"#{merge_list.join(',')}\"")
					merge_list = []
				end
			}
			sh_rdf.close()
		}
		sh_clr.close()
		if merge_list.length > 0
			sh_merge.puts("rake solr_index:merge_archive archive=\"#{merge_list.join(',')}\"")
		end
		sh_merge.puts("rake solr:optimize core=resources\"")
		sh_merge.close()

#		sh_all.puts("rake ecco:mark_for_textwright\n")

		sh_all.close()
	end

	def index_archive(msg, archive, type)
		flags = nil
		case type
			when :spider
				flags = "-mode spider"
				puts "~~~~~~~~~~~ #{msg} \"#{archive}\" [see log/#{archive}_progress.log and log/#{archive}_spider_error.log]"
			when :index
				flags = "-mode index -delete"
				puts "~~~~~~~~~~~ #{msg} \"#{archive}\" [see log/#{archive}_progress.log and log/#{archive}_error.log]"
			when :debug
				flags = "-mode test"
				puts "~~~~~~~~~~~ #{msg} \"#{archive}\" [see log/#{archive}_progress.log and log/#{archive}_error.log]"
		end

		if flags == nil
			puts "Call with either :spider, :index or :debug"
		else
			folders = get_folders(RDF_PATH, archive)
			if folders[:error]
				puts folders[:error]
			else
				safe_name = Solr::archive_to_core_name(archive)
				log_dir = "#{Rails.root}/log"
				case type
					when :spider
						TaskUtilities.delete_file("#{log_dir}/#{safe_name}_spider_error.log")
					when :index, :debug
						TaskUtilities.delete_file("#{log_dir}/#{safe_name}_error.log")
				end
				TaskUtilities.delete_file("#{log_dir}/#{safe_name}_progress.log")
				TaskUtilities.delete_file("#{log_dir}/#{safe_name}_error.log")
				TaskUtilities.delete_file("#{log_dir}/#{safe_name}_link_data.log")
				TaskUtilities.delete_file("#{log_dir}/#{safe_name}_duplicates.log")

				folders[:folders].each { |folder|
					cmd_line("cd #{Rails.root}/lib/tasks/rdf-indexer/target && java -Xmx3584m -jar rdf-indexer.jar -logDir \"#{log_dir}\" -source #{RDF_PATH}/#{folder} -archive \"#{archive}\" #{flags}")
				}
			end
		end
	end

	def compare_indexes_java (archive, page_size = 500, mode = nil)

		flags = ""
		safe_name = Solr::archive_to_core_name(archive)
		log_dir = "#{Rails.root}/log"

		# no mode specified = full compare on al fields.
		# delete all log files
		if mode.nil?
			TaskUtilities.delete_file("#{log_dir}/#{safe_name}_compare.log")
			TaskUtilities.delete_file("#{log_dir}/#{safe_name}_compare_text.log")
		else
			# if just txt compare is requested, ony delete txt log
			if mode == "compareTxt"
				flags = "-include text"
				TaskUtilities.delete_file("#{log_dir}/#{safe_name}_compare_text.log")
			end

			# if non-txt compare is requested, only delete the compare log
			if mode == "compare"
				flags = "-ignore text"
				TaskUtilities.delete_file("#{log_dir}/#{safe_name}_compare.log")
			end
		end

		# skipped is always deleted
		TaskUtilities.delete_file("#{log_dir}/#{safe_name}_skipped.log")

		# launch the tool
		cmd_line("cd #{Rails.root}/lib/tasks/rdf-indexer/target && java -Xmx3584m -jar rdf-indexer.jar -logDir \"#{log_dir}\" -archive \"#{archive}\" -mode compare #{flags} -pageSize #{page_size}")

	end

	def test_archive(archive)
		puts "~~~~~~~~~~~ testing \"#{archive}\" [see log/#{archive}_*.log]"
		folders = get_folders(RDF_PATH, archive)
		if folders[:error]
			puts "The archive entry for \"#{archive}\" was not found in any sitemap.yml file."
		else
				folders[:folders].each {|folder|
					find_duplicate_uri(folder, archive)
				}

			page_size = folders[:page_size].to_s
			compare_indexes_java(archive, page_size)
		end
	end

	def do_archive(split = :split)
		archive = ENV['archive']
		if archive == nil
			puts "Usage: call with archive=XXX,YYY"
		else
			start_time = Time.now
			if split == :split
				archives = archive.split(',')
				archives.each { |a| yield a }
			else
				yield archive
			end
			finish_line(start_time)
		end
	end

	def find_duplicate_uri(folder, archive)
		puts "~~~~~~~~~~~ Searching for duplicates in \"#{RDF_PATH}/#{folder}\" ..."
		puts "creating folder list..."
		directories = TaskUtilities.get_folder_tree("#{RDF_PATH}/#{folder}", [])

		directories.each { |dir|
			TaskReporter.set_report_file("#{Rails.root}/log/#{Solr.archive_to_core_name(archive)}_duplicates.log")
			puts "scanning #{dir} ..."
			all_objects_raw = `find #{dir}/* -maxdepth 0 -print0 | xargs -0 grep "rdf:about"` # just do one folder at a time so that grep isn't overwhelmed.
			all_objects_raw = all_objects_raw.split("\n")
			all_objects = {}
			all_objects_raw.each { |obj|
				arr = obj.split(':', 2)
				arr1 = obj.split('rdf:about="', 2)
				arr2 = arr1[1].split('"')
				if all_objects[arr2[0]] == nil
					all_objects[arr2[0]] = arr[0]
				else
					TaskReporter.report_line("Duplicate: #{arr2[0]} in #{all_objects[arr2[0]]} and #{arr[0]}")
				end
			}
		}
	end

	def merge_archive(archive)
		puts "~~~~~~~~~~~ Merging archive(s) #{archive} ..."
		archives = archive.split(',')
		solr = Solr.factory_create(:live)
		archive_list = []
		archives.each{|arch|
			index_name = Solr.archive_to_core_name(arch)
			solr.remove_archive(arch, false)
			archive_list.push("archive_#{index_name}")
		}
		solr.merge_archives(archive_list)

	end

	#############################################################
	## TASKS
	#############################################################

	desc "Look for duplicate objects in rdf folders (param: folder=subfolder_under_rdf,archive)"
	task :find_duplicate_objects => :environment do
		folder = ENV['folder']
		arr = folder.split(',') if folder
		if arr == nil || arr.length != 2
			puts "Usage: call with folder=folder,archive"
		else
			folder = arr[0]
			archive = arr[1]
			start_time = Time.now
			find_duplicate_uri(folder, archive)
			finish_line(start_time)
		end
	end

	desc "Index documents from the rdf folder to the reindex core (param: archive=XXX,YYY)"
	task :index  => :environment do
		do_archive { |archive| index_archive("Index", archive, :index) }
	end

	desc "Test one RDF archive (param: archive=XXX,YYY)"
	task :archive_test => :environment do
		do_archive { |archive| test_archive(archive) }
	end

	desc "Do the initial indexing of a folder to the archive_* core (param: archive=XXX,YYY)"
	task :debug => :environment do
		do_archive { |archive| index_archive("Debug", archive, :debug) }
	end

	desc "Index and test one rdf archive (param: archive=XXX,YYY)"
	task :index_and_test => :environment do
		do_archive { |archive|
			index_archive("Index", archive, :index)
			test_archive(archive)
		}
	end

	desc "Spider the archive for the full text and place results in rawtext. No indexing performed. (param: archive=XXX,YYY)"
	task :spider_rdf_text => :environment do
		do_archive { |archive| index_archive("Spider text", archive, :spider) }
	end

	desc "Merge one archive into the \"resources\" index (param: archive=XXX,YYY)"
	task :merge_archive => :environment do
		do_archive(:as_one) { |archives| merge_archive(archives) }
	end
end