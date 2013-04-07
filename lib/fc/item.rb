# encoding: utf-8

module FC
  class Item < DbBase
    set_table :items, 'name, tag, outer_id, policy_id, dir, size, status, time, copies'
    
    # create item by local path 
    # TODO проверка curr_host и local_path одному из доступных стораджей -> создание без копирования (для кусочков)
    def self.create_from_local(local_path, item_name, policy, options={})
      raise 'Path not exists' unless File.exists?(local_path)
      raise 'Policy is not FC::Policy' unless policy.instance_of?(FC::Policy)
      item_params = options.merge({
        :name => item_name.to_s.gsub('//', '/').sub(/\/$/, '').sub(/^\//, '').strip,
        :policy_id => policy.id,
        :dir => File.directory?(local_path),
        :size => `du -sb #{local_path}`.to_i
      })
      item_params.delete(:replace)
      raise 'Name is empty' if item_params[:name].empty?
      raise 'Zero size path' if item_params[:size] == 0
      
      # new item?
      item = FC::Item.where('name=? AND policy_id=?', item_params[:name], policy.id).first
      if item
        if options[:replace]
          # mark delete item_storages on replace
          FC::DB.connect.query("UPDATE #{FC::ItemStorage.table_name} SET status='delete' WHERE item_id = #{item.id}")
          # replace all fields
          item_params.each{|key, val| item.send("#{key}=", val)}
        else
          FC::Error.raise 'Item already exists', :item_id => item.id
        end
      else
        item = FC::Item.new(item_params)
      end
      item.save
      
      storage = policy.get_proper_storage(item.size)
      FC::Error.raise 'No available storage', :item_id => item.id unless storage
      
      item_storage = item.make_item_storage(storage)
      item.copy_item_storage(local_path, storage, item_storage)
      return item
    end
    
    def make_item_storage(storage, status = 'new')
      # new storage_item?
      item_storage = FC::ItemStorage.where('item_id=? AND storage_name=?', id, storage.name).first
      item_storage.delete if item_storage
      
      item_storage = FC::ItemStorage.new({:item_id => id, :storage_name => storage.name, :status => status})
      item_storage.save
      item_storage
    end
    
    def copy_item_storage(src, storage, item_storage)
      begin
        if src.instance_of?(FC::Storage)
          src.copy_to_local(name, "#{storage.path}#{name}")
        else
          storage.copy_path(src, name)
        end
        size_on_storage = storage.file_size(name)
      rescue Exception => e
        item_storage.status = 'error'
        item_storage.save
        FC::Error.raise "Copy error: #{e.message}", :item_id => id, :item_storage_id => item_storage.id
      else
        begin
          item_storage.reload
        rescue Exception => e
          FC::Error.raise "After copy error: #{e.message}", :item_id => id, :item_storage_id => item_storage.id
        else
          if size_on_storage != size
            item_storage.status = 'error'
            item_storage.save
            FC::Error.raise "Check size after copy error", :item_id => id, :item_storage_id => item_storage.id
          else
            item_storage.status = 'ready'
            item_storage.save
            reload
          end
        end
      end
    end
    
    # mark items_storages for delete
    def mark_deleted
      FC::DB.connect.query("UPDATE #{FC::ItemStorage.table_name} SET status='delete' WHERE item_id = #{id}")
      self.status = 'delete'
      save
    end
    
    def dir?
      dir.to_i == 1
    end
    
    def get_item_storages
      FC::ItemStorage.where("item_id = #{id}")
    end
  end
end
