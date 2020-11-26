# == Schema Information
#
# Table name: searches
#
#  id         :integer          not null, primary key
#  query      :string(255)      not null
#  person_id  :integer
#  created_at :datetime         not null
#  params     :text             default({})
#

class Search < ApplicationRecord
  serialize :params

  # RELATIONSHIPS
  belongs_to :person

  # INSTANCE METHODS
  def results
    json = begin
      if query =~ /^https?:\/\//
        if !(object = Tracker.magically_turn_url_into_tracker_or_issue(query))
          {} # URL not matched, render no results
        elsif object.is_a?(Issue)
          { async?: false, issue: object }
        elsif object.is_a?(Tracker)
          # If we just created this Tracker model, it requires a remote_sync. We cannot confidently perform this
          # synchronously, because it may take a long time if the Tracker has a lot of issues, so return a Delayed::Job
          # id for polling.
          if object.respond_to?(:magically_created?) && object.magically_created?
            job = object.delay.remote_sync(force: true, state: "open")
            { async?: true, job_id: job.id, tracker: object }
          else
            { async?: false, tracker: object }
          end
        else
          raise "This should never happen!"
        end
      else
        local_trackers_and_issues
        # TODO: add github repo search
      end
    end
    OpenStruct.new(json)
  end

  def self.tracker_typeahead(query)
    tracker_search = Tracker.search(query, fields: [:name], order: {_score: :desc, bounty_total: :desc}, match: :word_start, limit: 5, boost_by: [:forks, :watchers]).to_a
    reject_merged_trackers!(tracker_search)
  end

  def self.bounty_search(params)
    page = params[:page] || 1
    per_page = params[:per_page].present? ? params[:per_page] : 20
    query = params[:search] || "*"
    direction = ['asc', 'desc'].include?(params[:direction]) ? params[:direction] : 'desc'
    order = ["bounty_total","updated_at", "created_at", "backers_count", "earliest_bounty", "participants_count", "thumbs_up_count", "remote_created_at"].include?(params[:order]) ? params[:order] : "bounty_total"
    category = params[:category] || "fiat"
    
    if category == "crypto"
      crypto_bounties = CryptoBounty.find_by_sql("SELECT * FROM public.crypto_bounties")
      cryptoIds = []
      queryString = ""
 
      crypto_bounties.each do |bounty|
        cryptoIds.push(bounty.issue_id)
      end
 
      cryptoIds = cryptoIds.uniq
 
      cryptoIds.each do |issue_id|
        queryString += "#{issue_id},"
      end
 
      queryString = queryString.chop
 
      bounties = Issue.find_by_sql("SELECT * FROM public.issues
      WHERE id IN (#{queryString}) AND can_add_bounty=true
      ORDER BY #{order} #{direction}");
 
    else
      bounties = Issue.find_by_sql("SELECT * FROM public.issues
        WHERE can_add_bounty=true AND bounty_total > 0
        ORDER BY #{order} #{direction}");
    end
      
    if query != "*"
      bounties = bounties.select { |bounty| bounty.title.include? query }
    end
    
    total_bounties = bounties.length()
    page = page.to_i
    if page > 1
      drop_first_n = (page - 1) * per_page
      puts drop_first_n
      bounties = bounties.drop(drop_first_n)
      bounties = bounties.take(per_page)
    else
      bounties = bounties.take(per_page)
    end
    
    ActiveRecord::Associations::Preloader.new.preload(bounties, [:issue_address, author: [:person], tracker: [:languages, :team]])
 
    {
      issues: bounties,
      issues_total: total_bounties
    }
  end

protected

  def self.parse_datetime(date_string)
    parsed_datetime = DateTime.strptime(date_string, "%m/%d/%Y") unless date_string.blank?
    if parsed_datetime.try(:<, DateTime.now)
      date_range = (parsed_datetime..DateTime.now)
    end
    date_range
  end

  def self.reject_merged_trackers!(search_results)
    tracker_ids = MergedModel.where(bad_id: search_results.map(&:id)).pluck(:bad_id)
    search_results.reject! { |tracker| tracker_ids.include?(tracker.id) }
    search_results
  end

  def self.reject_merged_issues!(search_results)
    tracker_ids = MergedModel.where(bad_id: search_results.map(&:id)).pluck(:bad_id)
    search_results.reject! { |issue| tracker_ids.include?(issue.tracker_id) }
    search_results
  end

  def local_trackers_and_issues
    # Filters out Trackers that have been merged.

    tracker_search = Tracker.search(query, 
      fields: [:name], 
      order: {bounty_total: :desc}, 
      match: :word_start, 
      boost_by: [:forks, :watchers],
      limit: 50).to_a
    self.class.reject_merged_trackers!(tracker_search)

    # Filters out Issues whose Trackers have been merged.
    issue_search = Issue.search(query, 
      order: { bounty_total: :desc }, 
      boost_by: {comments_count: {factor: 10}}, 
      fields: ["title^50", "tracker_name^25", "languages_name^5", "body"],
      limit: 50
    ).to_a

    self.class.reject_merged_issues!(issue_search)

    {
      trackers: tracker_search,
      trackers_total: tracker_search.count,
      issues: issue_search,
      issues_total: issue_search.count
    }
  end

end
