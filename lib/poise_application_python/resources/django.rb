#
# Copyright 2015, Noah Kantrowitz
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require 'uri'

require 'chef/provider'
require 'chef/resource'
require 'poise'
require 'poise_application'
require 'poise_python'

require 'poise_application_python/app_mixin'
require 'poise_application_python/error'


module PoiseApplicationPython
  module Resources
    # (see Django::Resource)
    # @since 4.0.0
    module Django
      # Aliases for Django database engine names. Based on https://github.com/kennethreitz/dj-database-url/blob/master/dj_database_url.py
      # Copyright 2014, Kenneth Reitz.
      ENGINE_ALIASES = {
        'postgres' => 'django.db.backends.postgresql_psycopg2',
        'postgresql' => 'django.db.backends.postgresql_psycopg2',
        'pgsql' => 'django.db.backends.postgresql_psycopg2',
        'postgis' => 'django.contrib.gis.db.backends.postgis',
        'mysql2' => 'django.db.backends.mysql',
        'mysqlgis' => 'django.contrib.gis.db.backends.mysql',
        'spatialite' => 'django.contrib.gis.db.backends.spatialite',
        'sqlite' => 'django.db.backends.sqlite3',
      }

      # An `application_django` resource to configure Django applications.
      #
      # @since 4.0.0
      # @provides application_django
      # @action deploy
      # @example
      #   application '/srv/myapp' do
      #     git '...'
      #     pip_requirements
      #     django do
      #       database do
      #         host node['rails_host']
      #       end
      #     end
      #     gunicorn do
      #       port 8080
      #     end
      #   end
      class Resource < Chef::Resource
        include PoiseApplicationPython::AppMixin
        provides(:application_django)
        actions(:deploy)

        # @!attribute path
        #   Application base path.
        #   @return [String]
        attribute(:path, kind_of: String, name_attribute: true)
        # @!attribute collectstatic
        #   Set to false to disable running manage.py collectstatic during
        #   deployment.
        #   @todo This could auto-detect based on config vars in settings?
        #   @return [Boolean]
        attribute(:collectstatic, equal_to: [true, false], default: true)
        # @!attribute database
        #   Option collector attribute for Django database configuration.
        #   @return [Hash]
        #   @example Setting via block
        #     database do
        #       engine 'postgresql'
        #       database 'blog'
        #     end
        #   @example Setting via URL
        #     database 'postgresql://localhost/blog'
        attribute(:database, option_collector: true, parser: :parse_database_url)
        # @!attribute local_settings
        #   Template content attribute for the contents of local_settings.py.
        #   @todo Redo this doc to cover the actual attributes created.
        #   @return [Poise::Helpers::TemplateContent]
        attribute(:local_settings, template: true, default_source: 'settings.py.erb', default_options: lazy { default_local_settings_options })
        # @!attribute local_settings_path
        #   Path to write local settings to. If given as a relative path,
        #   will be expanded against {#path}. Set to false to disable writing
        #   local settings. Defaults to local_settings.py next to
        #   {#setting_module}.
        #   @return [String, nil false]
        attribute(:local_settings_path, kind_of: [String, NilClass, FalseClass], default: lazy { default_local_settings_path })
        # @!attribute migrate
        #   Run database migrations. This is a bad idea for real apps. Please
        #   do not use it.
        #   @return [Boolean]
        attribute(:migrate, equal_to: [true, false], default: false)
        # @!attribute manage_path
        #   Path to manage.py. Defaults to scanning for the nearest manage.py
        #   to {#path}.
        #   @return [String]
        attribute(:manage_path, kind_of: String, default: lazy { default_manage_path })
        # @!attribute settings_module
        #   Django settings module in dotted notation. Set to false to disable
        #   anything related to settings. Defaults to scanning for the nearest
        #   settings.py to {#path}.
        #   @return [Boolean]
        attribute(:settings_module, kind_of: [String, NilClass, FalseClass], default: lazy { default_settings_module })
        # @!attribute syncdb
        #   Run database sync. This is a bad idea for real apps. Please do not
        #   use it.
        #   @return [Boolean]
        attribute(:syncdb, equal_to: [true, false], default: false)
        # @!attribute wsgi_module
        #   WSGI application module in dotted notation. Set to false to disable
        #   anything related to WSGI. Defaults to scanning for the nearest
        #   wsgi.py to {#path}.
        #   @return [Boolean]
        attribute(:wsgi_module, kind_of: [String, NilClass, FalseClass], default: lazy { default_wsgi_module })

        private

        def default_local_settings_options
          raise todo
        end

        def default_local_settings_path
          # If no settings module, no default local settings.
          return unless settings_module
          settings_path = PoisePython::Utils.module_to_path(settings_module, path)
          ::File.expand_path(::File.join('..', 'local_settings.py'), settings_path)
        end

        def default_manage_path
          find_file('manage.py')
        end

        def default_settings_module
          PoisePython::Utils.path_to_module(find_file('settings.py'), path)
        end

        def default_wsgi_module
          PoisePython::Utils.path_to_module(find_file('wsgi.py'), path)
        end

        # Format a URL for DATABASES.
        #
        # @return [Hash]
        def parse_database_url(url)

          parsed = URI(url)
          {}.tap do |db|
            # Store this for use later in #set_state, and maybe future use by
            # Django in some magic world where operability happens.
            db[:URL] = url
            db[:ENGINE] = ENGINE_ALIASES[parsed.scheme] || "django.db.backends.#{parsed.scheme}" if parsed.scheme && !parsed.scheme.empty?
            # Strip the leading /.
            path = parsed.path ? parsed.path[1..-1] : parsed.path
            # If we are using SQLite, make it an absolute path.
            path = ::File.expand_path(path, self.path) if db[:ENGINE].include?('sqlite')
            db[:NAME] = path if path && !path.empty?
            db[:USER] = parsed.user if parsed.user && !parsed.user.empty?
            db[:PASSWORD] = parsed.password if parsed.password && !parsed.password.empty?
            db[:HOST] = parsed.host if parsed.host && !parsed.host.empty?
            db[:PORT] = parsed.port if parsed.port && !parsed.port.empty?
          end
        end

        def find_file(name)
          Dir[::File.join(path, '**', name)].min do |a, b|
            cmp = a.count(::File::SEPARATOR) <=> b.count(::File::SEPARATOR)
            if cmp == 0
              cmp = a <=> b
            end
            cmp
          end.tap do |p|
            raise PoiseApplicationPython::Error.new("Unable to find a file matching #{name}") unless p
          end
        end

      end

      class Provider < Chef::Provider
        include PoiseApplicationPython::AppMixin
        provides(:application_django)

        def action_deploy
          set_state
          notifying_block do
            run_syncdb
            run_migrate
            run_collectstatic
            write_config
          end
        end

        private

        def set_state
          # Set environment variables for later services.
          new_resource.app_state_environment[:DJANGO_SETTINGS_MODULE] = new_resource.settings_module if new_resource.settings_module
          new_resource.app_state_environment[:DATABASE_URL] = new_resource.database[:URL] if new_resource.database[:URL]
          # Set the app module.
          new_resource.app_state[:python_app_module] = new_resource.wsgi_module if new_resource.wsgi_module
        end

        def run_syncdb
          manage_py_execute('syncdb', '--noinput') if new_resource.syncdb
        end

        def run_migrate
          manage_py_execute('migrate', '--noinput') if new_resource.migrate
        end

        def run_collectstatic
          manage_py_execute('collectstatic', '--noinput') if new_resource.collectstatic
        end

        def write_config
          # Allow disabling the local settings.
          return unless new_resource.local_settings_path
          # todo
        end

        def manage_py_execute(*cmd)
          python_execute "manage.py #{cmd.join(' ')}" do
            python_from_parent new_resource
            command [new_resource.manage_path] + cmd
            environment new_resource.app_state_environment
            cwd new_resource.path
          end
        end

      end
    end
  end
end