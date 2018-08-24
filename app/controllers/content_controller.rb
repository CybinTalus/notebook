class ContentController < ApplicationController
  # todo before_action :load_content to set @content
  before_action :authenticate_user!, only: [:index, :new, :create, :edit, :update, :destroy]
  before_action :migrate_old_style_field_values, only: [:show, :edit]

  def index
    @content_type_class = content_type_from_controller(self.class)
    pluralized_content_name = @content_type_class.name.downcase.pluralize

    if @universe_scope.present? && @content_type_class != Universe
      @content = @universe_scope.send(pluralized_content_name)
    else
      @content = (
        current_user.send(pluralized_content_name) +
        current_user.send("contributable_#{pluralized_content_name}")
      )

      unless @content_type_class == Universe
        my_universe_ids = current_user.universes.pluck(:id)
        @content.concat(@content_type_class.where(universe_id: my_universe_ids))
      end
    end

    @content = @content.to_a.flatten.uniq.sort_by(&:name)

    @questioned_content = @content.sample
    @question = @questioned_content.question unless @questioned_content.nil?

    # Create the default fields for this user if they don't have any already
    @content_type_class.attribute_categories(current_user)

    respond_to do |format|
      format.html { render 'content/index' }
      format.json { render json: @content }
    end
  end

  def show
    content_type = content_type_from_controller(self.class)
    # TODO: Secure this with content class whitelist lel
    @content = content_type.find(params[:id])

    return if ENV.key?('CONTENT_BLACKLIST') && ENV['CONTENT_BLACKLIST'].split(',').include?(@content.user.email)

    if (current_user || User.new).can_read? @content
      @question = @content.question if current_user.present? and current_user == @content.user

      if current_user
        if @content.updated_at > 30.minutes.ago
          Mixpanel::Tracker.new(Rails.application.config.mixpanel_token).track(current_user.id, 'viewed content', {
            'content_type': content_type.name,
            'content_owner': current_user.present? && current_user.id == @content.user_id,
            'logged_in_user': current_user.present?
          }) if Rails.env.production?
        else
          Mixpanel::Tracker.new(Rails.application.config.mixpanel_token).track(current_user.id, 'viewed recently-modified content', {
            'content_type': content_type.name,
            'content_owner': current_user.present? && current_user.id == @content.user_id,
            'logged_in_user': current_user.present?
          }) if Rails.env.production?
        end
      end

      respond_to do |format|
        format.html { render 'content/show', locals: { content: @content } }
        format.json { render json: @content }
      end
    else
      return redirect_to root_path, notice: "You don't have permission to view that content."
    end
  end

  def new
    @content = content_type_from_controller(self.class)
               .new

    unless (current_user || User.new).can_create?(content_type_from_controller self.class)
      return redirect_to :back
    end

    respond_to do |format|
      format.html { render 'content/new', locals: { content: @content } }
      format.json { render json: @content }
    end
  end

  def edit
    @content = content_type_from_controller(self.class)
               .find(params[:id])

    unless @content.updatable_by? current_user
      return redirect_to @content, notice: t(:no_do_permission)
    end

    respond_to do |format|
      format.html { render 'content/edit', locals: { content: @content } }
      format.json { render json: @content }
    end
  end

  def create
    content_type = content_type_from_controller self.class
    initialize_object

    unless current_user.can_create?(content_type)
      return redirect_to :back
    end

    #  Don't set name fields on content that doesn't have a name field
    #todo abstract this (and the one in update) to a function
    unless [AttributeCategory, AttributeField, Attribute].map(&:name).include?(@content.class.name)
      @content.name = @content.name_field_value
    end

    Mixpanel::Tracker.new(Rails.application.config.mixpanel_token).track(current_user.id, 'created content', {
      'content_type': content_type.name
    }) if Rails.env.production?

    @content.user = current_user
    if @content.save
      @content.update(name: @content.name_field_value)
      if params.key? 'image_uploads'
        upload_files params['image_uploads'], content_type.name, @content.id
      end

      successful_response(content_creation_redirect_url, t(:create_success, model_name: humanized_model_name))
    else
      failed_response('new', :unprocessable_entity)
    end
  end

  def update
    content_type = content_type_from_controller(self.class)
    @content = content_type.find(params[:id])

    unless @content.updatable_by?(current_user)
      return redirect_to :back
    end

    Mixpanel::Tracker.new(Rails.application.config.mixpanel_token).track(current_user.id, 'updated content', {
      'content_type': content_type.name
    }) if Rails.env.production?

    if params.key? 'image_uploads'
      upload_files params['image_uploads'], content_type.name, @content.id
    end

    if @content.is_a?(Universe) && params.key?('contributors') && @content.user == current_user
      params[:contributors][:email].reject(&:blank?).each do |email|
        ContributorService.invite_contributor_to_universe(universe: @content, email: email.downcase)
      end
    end

    #  Don't set name fields on content that doesn't have a name field
    unless [AttributeCategory, AttributeField, Attribute].map(&:name).include?(@content.class.name)
      @content.name = @content.name_field_value
    end
    if @content.user == current_user
      update_success = @content.update_attributes(content_params)
    else
      # Exclude fields only the real owner can edit
      #todo move field list somewhere when it grows
      update_success = @content.update_attributes(content_params.except(:universe_id))
    end

    if update_success
      successful_response(@content, t(:update_success, model_name: humanized_model_name))
    else
      failed_response('edit', :unprocessable_entity)
    end
  end

  def upload_files image_uploads_list, content_type, content_id
    image_uploads_list.each do |image_data|
      image_size_kb = File.size(image_data.tempfile.path) / 1000.0

      if current_user.upload_bandwidth_kb < image_size_kb
        flash[:alert] = [
          "At least one of your images failed to upload because you do not have enough upload bandwidth.",
          "<a href='#{subscription_path}' class='btn white black-text center-align'>Get more</a>"
        ].map { |p| "<p>#{p}</p>" }.join
        next
      else
        current_user.update(upload_bandwidth_kb: current_user.upload_bandwidth_kb - image_size_kb)
      end

      related_image = ImageUpload.create(
        user: current_user,
        content_type: content_type,
        content_id: content_id,
        src: image_data,
        privacy: 'public'
      )

      Mixpanel::Tracker.new(Rails.application.config.mixpanel_token).track(current_user.id, 'uploaded image', {
        'content_type': content_type,
        'image_size_kb': image_size_kb,
        'first five images': current_user.image_uploads.count <= 5
      }) if Rails.env.production?
    end
  end

  def destroy
    content_type = content_type_from_controller(self.class)
    @content = content_type.find(params[:id])

    unless current_user.can_delete? @content
      return redirect_to :back, notice: "You don't have permission to do that!"
    end

    Mixpanel::Tracker.new(Rails.application.config.mixpanel_token).track(current_user.id, 'deleted content', {
      'content_type': content_type.name
    }) if Rails.env.production?

    @content.destroy

    successful_response(content_deletion_redirect_url, t(:delete_success, model_name: humanized_model_name))
  end

  def attributes
    @content_type = params[:content_type]
    # todo make this a before_action load_content_type
    unless valid_content_types.map { |c| c.name.downcase }.include?(@content_type)
      raise "Invalid content type on attributes customization page: #{@content_type}"
    end
    @content_type_class = @content_type.titleize.constantize
  end

  private

  def migrate_old_style_field_values
    @content = content_type_from_controller(self.class).find(params[:id])

    # Ensure the default attributes are created before  using them
    @content.class.attribute_categories(current_user)
    attribute_categories = @content.class.attribute_categories(current_user)
    attribute_fields = attribute_categories.flat_map(&:attribute_fields)

    attribute_fields.each do |attribute_field|
      next unless attribute_field.old_column_source.present?

      existing_value = attribute_field
        .attribute_values
        .where(entity_id: @content.id)
        .first

      if existing_value
        existing_value.update(value: @content.send(attribute_field.old_column_source))
      else
        raise "no"
        attribute_field.attribute_values.create(
          user_id: current_user.id,
          entity_type: @content.class.name,
          entity_id: @content.id,
          value: @content.send(attribute_field.old_column_source),
          privacy: 'private' # todo just make this the default for the column instead
        )
      end
    end
  end

  def valid_content_types
    Rails.application.config.content_types[:all]
  end

  def initialize_object
    content_type = content_type_from_controller(self.class)
    @content = content_type.new(content_params).tap do |c|
      c.user_id = current_user.id
    end
  end

  def content_params
    content_class = content_type_from_controller(self.class)
      .name
      .downcase
      .to_sym

    params.require(content_class).permit(content_param_list)
  end

  def content_deletion_redirect_url
    send("#{@content.class.name.underscore.pluralize}_path")
  end

  def content_creation_redirect_url
    params[:redirect_override].presence || @content
  end

  def content_symbol
    content_type_from_controller(self.class).to_s.downcase.to_sym
  end

  def successful_response(url, notice)
    respond_to do |format|
      format.html {
        if params.key?(:override) && params[:override].key?(:redirect_path)
          redirect_to params[:override][:redirect_path], notice: notice
        else
          redirect_to url, notice: notice
        end
      }
      format.json { render json: @content || {}, status: :success, notice: notice }
    end
  end

  def failed_response(action, status)
    respond_to do |format|
      format.html { render action: action }
      format.json { render json: @content.errors, status: status }
    end
  end

  def humanized_model_name
    content_type_from_controller(self.class).model_name.human
  end
end
