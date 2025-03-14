# typed: false
# frozen_string_literal: true

class Episode < ApplicationRecord
  include DbActivityMethods
  include Unpublishable
  include GraphqlResolvable

  DIFF_FIELDS = %i[
    number sort_number sc_count title prev_episode_id fetch_syobocal raw_number title_en
  ].freeze

  counter_culture :work, column_name: ->(episode) { episode.published? ? :episodes_count : nil }

  belongs_to :prev_episode,
    class_name: "Episode",
    optional: true
  belongs_to :work, touch: true
  has_many :db_activities, as: :trackable, dependent: :destroy
  has_many :db_comments, as: :resource, dependent: :destroy
  has_many :episode_records
  has_many :records, through: :episode_records
  has_many :library_entries, foreign_key: :next_episode_id, dependent: :nullify
  has_many :slots, dependent: :nullify

  validates :sort_number, presence: true, numericality: {only_integer: true}

  scope :recorded, -> { where("episode_records_count > 0") }

  after_create :update_prev_episode
  before_destroy :unset_prev_episode_id

  def self.next_episode(watched_episode_ids = [])
    only_kept.where.not(id: watched_episode_ids).order(:sort_number).first
  end

  def next_episode
    @next_episode ||= work.episodes.only_kept.find_by(prev_episode: self)
  end

  def number_title
    "#{number}「#{title}」"
  end

  def commented_episode_records_count
    episode_record_bodies_count
  end

  # 映画やOVAなどの実質エピソードを持たない作品かどうかを判定する
  def single?
    number.blank? && title.present? && title == work.title
  end

  def to_hash
    JSON.parse(to_json)
  end

  def to_diffable_hash
    data = self.class::DIFF_FIELDS.each_with_object({}) { |field, hash|
      hash[field] = send(field) if send(field).present?
      hash
    }

    data.delete_if { |_, v| v.blank? }
  end

  def records_chart_dataset
    current_month = Date.today.beginning_of_month
    count = 0
    [
      current_month.months_ago(3),
      current_month.months_ago(2),
      current_month.months_ago(1),
      current_month
    ].map { |date|
      count += episode_records.by_month(date).count
      {
        date: date.to_time.to_datetime.strftime("%Y/%m/%d"),
        value: count
      }
    }.to_json
  end

  def rating_state_chart_dataset
    all_records_count = episode_records.where.not(rating_state: nil).count
    EpisodeRecord.rating_state.values.map { |state|
      state_records_count = episode_records.with_rating_state(state).count
      ratio = state_records_count / all_records_count.to_f
      {
        name: state.text,
        name_key: state,
        quantity: state_records_count,
        percentage: ratio.nan? ? 0 : (ratio * 100).round
      }
    }.to_json
  end

  def local_number
    return number if I18n.locale == :ja
    return "##{raw_number}" if raw_number

    number
  end

  def last_record_watched_at
    episode_records.select(:created_at).last&.created_at
  end

  def build_episode_record(user:, watched_at:, rating: nil, deprecated_rating: nil, comment: "")
    episode_record = episode_records.new(
      user: user,
      rating_state: rating&.downcase,
      rating: deprecated_rating,
      body: comment
    )
    episode_record.work = work
    episode_record.detect_locale!(:body)
    episode_record.build_record(user: user, work: work, watched_at: watched_at)
    episode_record
  end

  private

  def unset_prev_episode_id
    return if next_episode.nil?

    # エピソードを削除するとき、次のエピソードの `prev_episode_id` に
    # 削除対象のエピソードが設定されていたとき、その情報を削除する
    next_episode.update_column(:prev_episode_id, nil) if self == next_episode.prev_episode
  end

  def update_prev_episode
    prev_episode = work.episodes.where.not(id: id).order(sort_number: :desc).first
    update_column(:prev_episode_id, prev_episode.id) if prev_episode
  end
end
