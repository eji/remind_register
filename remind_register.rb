#!/usr/bin/env ruby

require 'date'
require 'faraday'
require 'faraday-cookie_jar'
require 'nokogiri'
require 'virtus'
require 'json'


class RemindRegister
  class Cybozu
    class ScheduleCollector
      EVENT_CONTENT_REGEXP = /\A(?<hour>\d{1,2}):(?<minute>\d{2})/

      def initialize(account, password, target_user_name)
        @account = account
        @password = password
        @target_user_name = target_user_name
      end

      def today
        @today ||= Date.today
      end

      # [Evnet]
      def collect
        login_cybozu
        res = conn.get '/scripts/cbag/ag.exe', 'page' => 'ScheduleUserDay',
                                               'gid' => 'virtual',
                                               'date' => today.strftime('da.%Y.%m.%d'),
                                               'Text' => @target_user_name.tr(' ', '+')
        fail '取得失敗' unless res.status == 200
        schedule_html = res.body
        doc = Nokogiri::HTML.parse(schedule_html)
        doc.xpath('//a[@class="event"]').map do |event|
          EVENT_CONTENT_REGEXP.match(event.content) do |m|
            start_time = Time.parse(today.strftime("%Y-%m-%dT#{m[:hour]}:#{m[:minute]}"))
            Event.new(name: event[:title], user_name: @target_user_name, start_time: start_time)
          end
        end.compact
      end

      private

      def login_cybozu
        res = conn.post '/scripts/cbag/ag.exe', '_System' => 'login',
                                                '_Login' => 1,
                                                'LoginMethod' => 2,
                                                '_Account' => @account,
                                                'Password' => @password,
                                                'Submit' => 'ログイン'
        fail 'ログイン失敗' unless res.status == 302
      end

      def conn
        @conn ||= Faraday.new(url: ENV['CYBOZU_URL_BASE']) do |faraday|
          faraday.request :url_encoded
          faraday.use :cookie_jar
          faraday.adapter Faraday.default_adapter
        end
      end
    end

    class Event
      include Virtus.model

      attribute :name, DateTime
      attribute :start_time, DateTime
      attribute :user_name, String

      def remind_time
        start_time - Rational(15, 24 * 60) # 15分前に通知
      end
    end
  end

  class Slack
    def register_reminds(events)
      events.each { |event| register_remind(event) }
    end

    def register_remind(event)
      conn.get ENV['SLACK_API_ADD_REMINDER_PATH'], {
        token: ENV['SLACK_TOKEN'],
        text: "@#{ENV['SLACK_REMIND_ACCOUNT']} #{event.start_time.strftime('%H:%M')} #{event.name}",
        time: event.remind_time.to_time.to_i,
        user: ENV['SLACK_REMIND_USER']
      }
    end

    private

    def conn
      @conn ||= Faraday.new(url: ENV['SLACK_API_BASE']) do |faraday|
        faraday.adapter Faraday.default_adapter
      end
    end
  end

  def register_remind_to_slack
    @schedule_collector = Cybozu::ScheduleCollector.new(ENV['CYBOZU_ACCOUNT'], ENV['CYBOZU_PASSWORD'], ENV['CYBOZU_USERNAME'])
    events = @schedule_collector.collect
    slack = Slack.new
    slack.register_reminds(events)
  end
end

if __FILE__ == $PROGRAM_NAME
  remind_register = RemindRegister.new
  remind_register.register_remind_to_slack
end
