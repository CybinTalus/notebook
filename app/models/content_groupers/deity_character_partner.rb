class DeityCharacterPartner < ActiveRecord::Base
  belongs_to :user
  belongs_to :deity
  belongs_to :character_partner, class_name: Character.name
end
