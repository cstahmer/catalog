class CreateWhiteLists < ActiveRecord::Migration
  def change
    create_table :white_lists do |t|
      t.string :ip

      t.timestamps
    end
  end
end
