package Koha::Plugin::Com::Biblibre::Electre;

use Modern::Perl;
use base       qw(Koha::Plugins::Base);
use Mojo::JSON qw(decode_json);
use C4::Context;
use C4::Koha      qw(NormalizeISBN);
use C4::Languages qw(getlanguage);

our $VERSION         = "3.2";
our $MINIMUM_VERSION = "23.05";

our $metadata = {
    name            => 'Plugin Electre',
    author          => 'Thibaud Guillot',
    date_authored   => '2024-11-18',
    date_updated    => '2026-08-25',
    minimum_version => $MINIMUM_VERSION,
    maximum_version => undef,
    version         => $VERSION,
    description     =>
      'This plugin implements enhanced content from Electre webservice',
    namespace => 'electre',
};

# Strings injected into intranet_cover_images/opac_cover_images JS, which is
# generated in Perl and never goes through Template Toolkit, so it can't use
# the i18n/*.inc + [% T.xxx %] mechanism used by configure.tt.
our %JS_STRINGS = (
    en => {
        cover_hint   => 'Electre cover image',
        image_hint   => 'Image from Electre',
        resume_label => 'Electre: ',
    },
    fr => {
        cover_hint   => 'Image de couverture Electre',
        image_hint   => "Image d'Electre",
        resume_label => 'Electre: ',
    },
);

sub new {
    my ( $class, $args ) = @_;

    $args->{'metadata'} = $metadata;
    $args->{'metadata'}->{'class'} = $class;

    my $self = $class->SUPER::new($args);

    $self->{config_table} = $self->get_qualified_table_name('config');

    return $self;
}

sub _lang {
    my ($self) = @_;

    my $lang = eval { getlanguage( $self->{'cgi'} ) } // '';

    return $lang =~ /^fr/i ? 'fr' : 'en';
}

sub _js_strings {
    my ($self) = @_;

    return $JS_STRINGS{ $self->_lang };
}

sub _translate_js {
    my ( $self, $js ) = @_;

    my $strings = $self->_js_strings();
    $js =~ s/__ELECTRE_COVER_HINT__/$strings->{cover_hint}/g;
    $js =~ s/__ELECTRE_IMAGE_HINT__/$strings->{image_hint}/g;
    $js =~ s/__ELECTRE_LABEL__/$strings->{resume_label}/g;

    return $js;
}

=head3 template_include_paths

Lets C4::Templates find this plugin's i18n/*.inc files (referenced from
configure.tt as "Koha/Plugin/Com/Biblibre/Electre/i18n/${LANG}.inc")
by adding this Koha instance's pluginsdir(s) to the Template Toolkit
INCLUDE_PATH.

=cut

sub template_include_paths {
    my ($self) = @_;

    my $pluginsdir = C4::Context->config('pluginsdir');
    my @pluginsdir = ref($pluginsdir) eq 'ARRAY' ? @$pluginsdir : $pluginsdir;

    return \@pluginsdir;
}

# Mandatory even if does nothing
sub install {
    my ( $self, $args ) = @_;

    return 1;
}

# Mandatory even if does nothing
sub upgrade {
    my ( $self, $args ) = @_;

    return 1;
}

# Mandatory even if does nothing
sub uninstall {
    my ( $self, $args ) = @_;

    return 1;
}

sub configure {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    unless ( $cgi->param('save') ) {
        my $template =
          $self->get_template( { file => 'templates/index/configure.tt' } );

        my $access_username = $self->retrieve_data('access_username') // undef;
        my $access_password = $self->retrieve_data('access_password') // undef;
        my $resume_on_staff = $self->retrieve_data('resume_on_staff') // 0;
        my $resume_on_opac  = $self->retrieve_data('resume_on_opac')  // 0;
        my $image_on_staff  = $self->retrieve_data('image_on_staff')  // 0;
        my $image_on_opac   = $self->retrieve_data('image_on_opac')   // 0;
        my $thumbnail_on_staff = $self->retrieve_data('thumbnail_on_staff')
          // 0;
        my $thumbnail_on_opac = $self->retrieve_data('thumbnail_on_opac') // 0;

        $template->param(
            access_username    => $access_username,
            access_password    => $access_password,
            resume_on_staff    => $resume_on_staff,
            resume_on_opac     => $resume_on_opac,
            image_on_staff     => $image_on_staff,
            image_on_opac      => $image_on_opac,
            thumbnail_on_staff => $thumbnail_on_staff,
            thumbnail_on_opac  => $thumbnail_on_opac,
        );

        $self->output_html( $template->output() );
    }
    else {
        my $data = {
            access_username => $cgi->param('access_username')
            ? $cgi->param('access_username')
            : undef,
            access_password => $cgi->param('access_password')
            ? $cgi->param('access_password')
            : undef,
            resume_on_staff    => $cgi->param('resume_on_staff')    ? 1 : 0,
            resume_on_opac     => $cgi->param('resume_on_opac')     ? 1 : 0,
            image_on_staff     => $cgi->param('image_on_staff')     ? 1 : 0,
            image_on_opac      => $cgi->param('image_on_opac')      ? 1 : 0,
            thumbnail_on_staff => $cgi->param('thumbnail_on_staff') ? 1 : 0,
            thumbnail_on_opac  => $cgi->param('thumbnail_on_opac')  ? 1 : 0,
        };

        $self->store_data($data);
        $self->go_home();
    }
}

sub api_routes {
    my ( $self, $args ) = @_;

    my $spec_dir = $self->mbf_dir();

    my $schema = JSON::Validator::Schema::OpenAPIv2->new;
    my $spec   = $schema->resolve( $spec_dir . '/openapi.yaml' );

    return $self->_convert_refs_to_absolute( $spec->data->{'paths'},
        'file://' . $spec_dir . '/' );
}

sub api_namespace {
    my ($self) = @_;

    return 'electre';
}

sub _convert_refs_to_absolute {
    my ( $self, $hashref, $path_prefix ) = @_;

    foreach my $key ( keys %{$hashref} ) {
        if ( $key eq '$ref' ) {
            if ( $hashref->{$key} =~ /^(\.\/)?openapi/ ) {
                $hashref->{$key} = $path_prefix . $hashref->{$key};
            }
        }
        elsif ( ref $hashref->{$key} eq 'HASH' ) {
            $hashref->{$key} =
              $self->_convert_refs_to_absolute( $hashref->{$key},
                $path_prefix );
        }
        elsif ( ref( $hashref->{$key} ) eq 'ARRAY' ) {
            $hashref->{$key} =
              $self->_convert_array_refs_to_absolute( $hashref->{$key},
                $path_prefix );
        }
    }
    return $hashref;
}

sub _convert_array_refs_to_absolute {
    my ( $self, $arrayref, $path_prefix ) = @_;

    my @res;
    foreach my $item ( @{$arrayref} ) {
        if ( ref($item) eq 'HASH' ) {
            $item = $self->_convert_refs_to_absolute( $item, $path_prefix );
        }
        elsif ( ref($item) eq 'ARRAY' ) {
            $item =
              $self->_convert_array_refs_to_absolute( $item, $path_prefix );
        }
        push @res, $item;
    }
    return \@res;
}

sub intranet_cover_images {
    my ($self) = @_;
    my $cgi = $self->{'cgi'};

    my $resume_on_staff = $self->retrieve_data('resume_on_staff') // 0;
    my $image_on_staff  = $self->retrieve_data('image_on_staff')  // 0;

    my $js = <<'JS';
    <script>
        function addElectreCover(e) {
            var promises = [];
            const search_results_images = document.querySelectorAll('.cover-slides, .cover-slider');
            const divDetail = $('#catalogue_detail_biblio .page-section');
            if(search_results_images.length){
                search_results_images.forEach((div, i) => {
                    let { isbn, biblionumber, processedbiblio } = div.dataset;
                    if (isbn && isbn.length == 10) {
                        let onResultPage = divDetail.length ? false : true;
                        if (!onResultPage) {
                            div.innerHTML += `
                                <div class="cover-image electre-loading" id="electre-coverimg${ biblionumber ? `-${biblionumber}` : '' }">
                                    <img src=""/>
                                    <div class="hint">__ELECTRE_COVER_HINT__</div>
                                </div>
                            `;
                        }
                        const promise = $.get(
                            `/api/v1/contrib/electre/image?isbn10=${isbn}&side=staff&result_page=${onResultPage}`, function( data ) {
                                if (data) {
                                    const hint = onResultPage ? `__ELECTRE_COVER_HINT__` : `__ELECTRE_IMAGE_HINT__`;
                                    const placeholder = div.querySelector('.electre-loading');
                                    if (placeholder) {
                                        placeholder.innerHTML = `
                                            <a href="${ processedbiblio ? processedbiblio : data }">
                                                <img src="${data}" alt="__ELECTRE_COVER_HINT__" />
                                            </a>
                                            <div class="hint">${hint}</div>
                                        `;
                                        placeholder.classList.remove('electre-loading');
                                    } else {
                                        div.innerHTML += `
                                                <div class="cover-image" id="electre-coverimg${ biblionumber ? `-${biblionumber}` : '' }">
                                                    <a href=${ processedbiblio ? processedbiblio : `${data}` } >
                                                        <img src="${data}" alt="__ELECTRE_COVER_HINT__" />
                                                    </a>
                                                    <div class="hint">${hint}</div>
                                                </div>
                                        `;
                                    }

                                    // Manually remove no-image div if present
                                    if(div.querySelector('.no-image')){
                                        div.querySelector('.no-image').remove();
                                    }
                                }
                            }
                        ).fail(function(xhr, status, error) {
                            console.error(xhr.responseJSON?.error || error);
                            const placeholder = div.querySelector('.electre-loading');
                            if (placeholder) {
                                placeholder.remove();
                            }
                        });
                        promises.push(promise);
                    }
                });
                Promise.allSettled(promises).then(() => {
                    $(".cover-nav").remove();
                    verify_cover_images();
                });
            }
        }
        function addElectreResume(e) {
            const divDetail = $('#catalogue_detail_biblio .page-section');
            if(divDetail.length) {
                const coverSliderDatas = document.querySelector('.cover-slides, .cover-slider').dataset;
                let isbn = coverSliderDatas.isbn;
                if (isbn && isbn.length == 10) {
                    $.get(
                        '/api/v1/contrib/electre/resume?isbn10=' + isbn + '&side=staff', function( data ) {
                            if (data) {
                                divDetail.append(`
                                        <span class="results_summary electre">
                                            <span class="label">__ELECTRE_LABEL__</span>
                                            <span id="electre-resume">${data}</span>
                                        </span>
                                `);
                            }
                        }
                    ).fail(function(xhr, status, error) {
                        console.error(xhr.responseJSON.error);
                    });
                }
            }
        }
JS

    $js .= "    document.addEventListener('DOMContentLoaded', addElectreCover, true);\n"
      if $image_on_staff;
    $js .= "    document.addEventListener('DOMContentLoaded', addElectreResume, true);\n"
      if $resume_on_staff;

    $js .= <<'JS';
    </script>
JS

    $js = $self->_translate_js($js);

    return "$js";
}

sub opac_cover_images {
    my ($self) = @_;
    my $cgi = $self->{'cgi'};

    my $resume_on_opac = $self->retrieve_data('resume_on_opac') // 0;
    my $image_on_opac  = $self->retrieve_data('image_on_opac')  // 0;

    my $js = <<'JS';
    <script>
        function addElectreCover(e) {
            var promises = [];
            const search_results_images = document.querySelectorAll('.cover-slides, .cover-slider');
            const divDetail = $('#catalogue_detail_biblio');
            if(search_results_images.length){
                search_results_images.forEach((div, i) => {
                    let { isbn, imgTitle } = div.dataset;
                    if (isbn && isbn.length == 10) {
                        let onResultPage = divDetail.length ? false : true;

                        div.innerHTML += `
                            <div class="cover-image electre-loading" id="electre-coverimg">
                                <img src=""/>
                            </div>
                        `;

                        const promise = $.get(
                             `/api/v1/contrib/electre/image?isbn10=${isbn}&side=opac&result_page=${onResultPage}`, function( data ) {
                                if (data) {
                                    const placeholder = div.querySelector('.electre-loading');
                                    if (placeholder) {
                                        if (onResultPage) {
                                            placeholder.innerHTML = `
                                                <a href="${data}">
                                                    <img src="${data}" alt="__ELECTRE_COVER_HINT__" />
                                                </a>
                                                <div class="hint">__ELECTRE_IMAGE_HINT__</div>
                                            `;
                                            placeholder.setAttribute('title', imgTitle || '');
                                        } else {
                                            placeholder.innerHTML = `
                                                <a href="${data}">
                                                    <img src="${data}" alt="__ELECTRE_COVER_HINT__" class="item-thumbnail" />
                                                    <div class="hint">__ELECTRE_IMAGE_HINT__</div>
                                                </a>
                                            `;
                                        }
                                        placeholder.classList.remove('electre-loading');
                                    }
                                }
                            }
                        ).fail(function(xhr, status, error) {
                            console.error(xhr.responseJSON?.error || error);
                            const placeholder = div.querySelector('.electre-loading');
                            if (placeholder) {
                                placeholder.remove();
                            }
                        });
                        promises.push(promise);
                    }
                });
                Promise.allSettled(promises).then(() => {
                    $('.cover-nav').remove();
                    verify_cover_images();
                });
            }
        }
        function addElectreResume(e) {
            const divDetail = $('#catalogue_detail_biblio');
            if(divDetail.length) {
                const coverSliderDatas = document.querySelector('.cover-slides, .cover-slider').dataset;
                let isbn = coverSliderDatas.isbn;
                if (isbn && isbn.length == 10) {
                    $.get(
                        '/api/v1/contrib/electre/resume?isbn10=' + isbn + '&side=opac', function( data ) {
                            if (data) {
                                divDetail.append(`
                                        <span class="results_summary electre">
                                            <span class="label">__ELECTRE_LABEL__</span>
                                            <span id="electre-resume">
                                                ${data}
                                            </span>
                                        </span>
                                `);
                            }
                        }
                    ).fail(function(xhr, status, error) {
                        console.error(xhr.responseJSON.error);
                    });
                }
            }
        }
JS

    $js .= "    document.addEventListener('DOMContentLoaded', addElectreCover, true);\n"
      if $image_on_opac;
    $js .= "    document.addEventListener('DOMContentLoaded', addElectreResume, true);\n"
      if $resume_on_opac;

    $js .= <<'JS';
    </script>
JS

    $js = $self->_translate_js($js);

    return "$js";
}

1;
