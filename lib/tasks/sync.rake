require "httparty"

namespace :sync do
  namespace :pdp do
    task :campaigns => :environment do
      campaigns = JSON.parse(HTTParty.get("#{ENV["PDP_HOST"]}/campaigns.json", query: {token: ENV["PDP_API_TOKEN"]}).body)
      campaigns.each do |campaign|
        mobilization = Mobilization.find_by_hashtag(campaign["hashtag"])
        if mobilization.present?
          Campaign.create(
            name:             campaign["name"],
            link:             "#{ENV["PDP_HOST"]}/campaigns/#{campaign["id"]}",
            description_html: campaign["description_html"],
            uid:              campaign["id"],
            hashtag:          mobilization.hashtag,
            user:             User.find_by_email(campaign["user_email"]),
            user_email:       campaign["user_email"]
          )
        end
      end
    end

    task :pokes, [:from, :until] => :environment do |t, args|
      date_until = args[:until]

      Campaign.all.each do |campaign|
        date_from = args[:from] || (campaign.pokes.last.created_at.strftime('%Y-%m-%d-%H-%M-%S') if campaign.pokes.any?)
        pokes = JSON.parse(HTTParty.get("#{ENV["PDP_HOST"]}/campaigns/#{campaign.uid}/pokes.json?from=#{date_from}&until=#{date_until}", query: {token: ENV["PDP_API_TOKEN"]}).body)
        Rails.logger.info "Found #{pokes.count} pokes in campaign #{campaign.uid} from #{date_from} until #{date_until}"
        pokes.each do |poke|
          Poke.create(
            uid:        poke["id"], 
            campaign:   campaign, 
            user:       User.find_by_email(poke["user"]["email"]), 
            user_email: poke["user"]["email"]
          )
        end
      end
    end
  end

  namespace :imagine do
    task :problems => :environment do
      problems = JSON.parse(HTTParty.get("#{ENV["IMAGINE_HOST"]}/problems.json?token=#{ENV["IMAGINE_API_TOKEN"]}").body)
      problems.each do |problem_hash|
        mobilization = Mobilization.find_by(hashtag: problem_hash["hashtag"])
        if mobilization.present?
          Problem.create(
            name:             problem_hash["title"],
            link:             "#{ENV['IMAGINE_HOST']}/problems/#{problem_hash['id']}",
            description:      problem_hash["description"],
            uid:              problem_hash["id"],
            hashtag:          mobilization.hashtag,
            user:             User.find_by_email(problem_hash["user"]["email"]),
            user_email:       problem_hash["user"]["email"]
          )

          problem = Problem.find_by(uid: problem_hash['id'].to_s)
          
          problem_hash['ideas'].each do |idea|
            Idea.create(
              name:             idea["title"],
              link:             "#{ENV["IMAGINE_HOST"]}/problems/#{problem_hash['id']}/ideas/#{idea['id']}",
              description:      idea["description"],
              uid:              idea["id"],
              problem:          problem,
              user:             User.find_by_email(idea["user"]["email"]),
              user_email:       idea["user"]["email"]
            )
          end if problem
        end
      end
    end
  end

  namespace :twitter do
    task :tweets => :environment do
      Mobilization.all.each do |mobilization|
        Twitter.search(mobilization.hashtag, result_type: 'recent').results.map do |tweet|
          Tweet.create(
            hashtag:      mobilization.hashtag,
            username:     tweet.from_user,
            text:         tweet.text,
            uid:          tweet.id,
            published_at: tweet.created_at
          )
        end
      end
    end

    task :favorites_and_retweets => :environment do
      Tweet.where("created_at >= ?", Time.current - 1.day).all.each do |tweet|
        status = Twitter.status(tweet.uid)
        tweet.update_attributes favorite_count: status.favourites_count, retweet_count: status.retweet_count
      end
    end
  end

  namespace :facebook do
    task :images_and_clippings => :environment do
      images = Koala::Facebook::API.new.get_connections("241897672509479", "photos", type: "uploaded", fields: "name,source,created_time,link").select{|image| image["name"].present?}
      images.each do |image|
        mobilization = Mobilization.where("hashtag IN (?)", image["name"].scan(/#[\S]+/).map{|h| h.delete("#")}).first
        if mobilization.present?
          if image["name"].match(/#NaMídia/)
            Clipping.create(
              remote_image_url: image["source"], 
              hashtag:          mobilization.hashtag, 
              uid:              image["id"],
              published_at:     Time.parse(image["created_time"]),
              link:             image["link"],
              body:             image["name"]
            )
          else
            Image.create remote_file_url: image["source"], hashtag: mobilization.hashtag, uid: image["id"]
          end
        end
      end
    end

    task :posts_by_hashtag => :environment do
      graph = Koala::Facebook::API.new(ENV["FB_APP_TOKEN"])
      Mobilization.all.each do |mobilization|
        begin
          posts = graph.search(mobilization.hashtag, fields: "from,message,created_time,id")
          posts.each do |post|
            FacebookPost.create(
              hashtag:      mobilization.hashtag,
              username:     post["from"]["name"],
              text:         post["message"],
              published_at: post["created_time"],
              user_uid:     post["from"]["id"],
              uid:          post["id"]
            )
          end
        rescue Exception => e
          Rails.logger.info "Could not update Mobilization ##{mobilization.id}"
          Rails.logger.info e.message
        end
      end
    end

    task :posts_by_meurio, [:limit] => :environment do |t, args|
      limit = args[:limit] || 25
      posts = Koala::Facebook::API.new(ENV["FB_APP_TOKEN"]).get_connections("241897672509479", "posts", fields: "from,message,created_time,id", limit: limit)
      posts.each do |post|
        Mobilization.all.each do |mobilization|
          next if post["message"].nil?
          begin
            if post["message"].index(mobilization.hashtag).present?
              FacebookPost.create(
                hashtag:      mobilization.hashtag,
                username:     post["from"]["name"],
                text:         post["message"],
                published_at: post["created_time"],
                user_uid:     post["from"]["id"],
                uid:          post["id"]
              )
            end
          rescue Exception => e
            Rails.logger.info "Could not create post #{post.inspect}"
            Rails.logger.info e.message
          end
        end
      end
    end

    task :events => :environment do
      events = Koala::Facebook::API.new(ENV["FB_APP_TOKEN"]).get_connections("241897672509479", "events", fields: "id,description,name").select{|event| event["description"].present?}
      events.each do |event|
        mobilization = Mobilization.where("hashtag IN (?)", event["description"].scan(/#[\S]+/).map{|h| h.delete("#")}).first
        if mobilization.present?
          Event.create(
            hashtag:     mobilization.hashtag, 
            name:        event["name"], 
            description: event["description"], 
            link:        "http://facebook.com/events/#{event['id']}",
            uid:         event["id"]
          )
        end
      end
    end

    task :attendees => :environment do
      graph = Koala::Facebook::API.new(ENV["FB_APP_TOKEN"])
      Event.all.each do |event|
        attending_count = graph.fql_query("SELECT attending_count FROM event WHERE eid = #{event.uid}").first["attending_count"]
        event.update_attributes attending_count: attending_count
      end
    end

    task :likes_shares_and_comments => :environment do
      graph = Koala::Facebook::API.new(ENV["FB_APP_TOKEN"])
      FacebookPost.where("created_at >= ? AND username = 'Meu Rio'", Time.current - 1.day).all.each do |fp|
        begin
          post = graph.get_object(fp.uid, fields: "shares,likes.limit(1).summary(1),comments.limit(1).summary(1)")
          if post["shares"].present?    then fp.share_count = post["shares"]["count"] end
          if post["likes"].present?     then fp.like_count = post["likes"]["summary"]["total_count"] end
          if post["comments"].present?  then fp.comment_count = post["comments"]["summary"]["total_count"] end
          fp.save!
        rescue Exception => e
          message = "Could not update FacebookPost ##{fp.id} | #{e.message}"
          Rails.logger.warn message
          puts message
        end
      end
    end
  end
end
